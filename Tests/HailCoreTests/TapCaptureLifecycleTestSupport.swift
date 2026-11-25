import Foundation
import HailCore

// The symlinked lifecycle/progress sources run the app's real capture and suppression code in SwiftPM. Only
// SwiftUI storage, permissions, session IO and unrelated UI helpers are replaced; no microphone is opened.
struct ConversationDestinationID: Hashable { let id: UUID }

@MainActor
final class TapCaptureTestSession {
    var holdDeactivation = false
    var deactivating = false
    private var waiter: CheckedContinuation<Void, Never>?
    func activate() async throws {}
    func deactivate() async {
        deactivating = true
        if holdDeactivation { await withCheckedContinuation { waiter = $0 } }
    }
    func releaseDeactivation() { waiter?.resume() }
}

@MainActor
final class TranscriptionLabView {
    let audioSession = TapCaptureTestSession()
    let playback: ReplyPlaybackController
    let talkSession: StationTalkSession
    var capture: any AudioCapturing { talkSession.resources.capture }
    var transcriber: any Transcriber { talkSession.resources.transcriber }
    var globalReplyAudioSpeaking: Bool { playback.isReplyAudioOutputBusy }
    var received: [TranscriptionResult] = []
    var onResult: (@MainActor (TranscriptionResult) -> Void)?
    let captureOwnerID = UUID()
    var isRecording = false, isStarting = false, isFinalizing = false, isInterrupting = false
    var isForcedTeardown = false, hasReceivedAudio = false, ownsCaptureSuppression = false
    var playbackRestoreRequested = false
    var finalText = "", volatileText = "", status = "Ready"
    var pendingSendID: UUID?, activeUtteranceID: UUID?, finishGeneration: UUID?
    var destinationGeneration = UUID()
    var pendingDestinationID: ConversationDestinationID?
    var startTask: Task<Void, Never>?, finishTask: Task<Void, Never>?
    var interruptTask: Task<Void, Never>?, bufferTask: Task<Void, Never>?, replyTimeoutTask: Task<Void, Never>?
    var onFinalized: (@MainActor (String) async -> Void)?
    var sent: [String] = []
    var scenePhase = ScenePhase.active
    enum ScenePhase { case active, background }

    convenience init(capture: any AudioCapturing, playback: ReplyPlaybackController, transcriber: any Transcriber) {
        self.init(talkSession: StationTalkSession {
            TranscriptionResources(capture: capture, transcriber: transcriber)
        }, playback: playback)
    }

    init(talkSession: StationTalkSession, playback: ReplyPlaybackController) {
        self.talkSession = talkSession
        self.playback = playback
    }

    // Optional callback properties match the app's surface for the symlinked progress code.
    var onCaptureWillBegin: (@MainActor (UUID) -> Void)? {
        { CapturePlaybackSuppression.begin($0, using: self.playback) }
    }
    var onCaptureDidEnd: (@MainActor (UUID, Bool) -> Void)? {
        { CapturePlaybackSuppression.end($0, using: self.playback, resuming: $1) }
    }

    func takeCaptureExclusivity() {
        // Identical to StationCard's registration; the lifecycle must replace stale UI recording liveness.
        CapturePlaybackSuppression.liveness[captureOwnerID] = { [self] in
            isStarting || isRecording || isFinalizing || isInterrupting || startTask != nil
        }
        if ownsCaptureSuppression { onCaptureWillBegin?(captureOwnerID) }
        beginCaptureExclusivity()
    }
    func prepareCaptureAuthorization() async -> Bool { true }
    func begin() async { await begin(whenVisible: { self.scenePhase == .active }) }
    func quietReplyAudio() async throws {}
    func receiveResult(_ result: TranscriptionResult) {
        received.append(result)
        onResult?(result)
    }
    func markAudioReceived() { hasReceivedAudio = true }
    func deactivateTalkRoute() async { await audioSession.deactivate() }
    func prepareForcedFinish() async -> Bool {
        let pendingStart = startTask
        pendingStart?.cancel()
        await deactivateTalkRoute()
        await pendingStart?.value
        guard let pendingInterrupt = interruptTask else { return false }
        await pendingInterrupt.value
        return true
    }
    func restorePlaybackAfterFinish() {
        if scenePhase == .active {
            isForcedTeardown = false
            endCaptureExclusivity(resumingPlayback: true)
        } else {
            CapturePlaybackSuppression.markCleanupComplete(captureOwnerID, using: playback)
            restorePlaybackIfRequestedAndReady()
        }
    }
    func clearPendingSend() {
        pendingSendID = nil
        pendingDestinationID = nil
    }
    func send(_ text: String, failurePrefix: String) async { sent.append(text) }
    func discardCapture() async {
        capture.stop()
        bufferTask?.cancel()
        bufferTask = nil
        activeUtteranceID = nil
        await transcriber.cancel()
        isRecording = false
    }
}

actor TapLifecycleTranscriber: Transcriber {
    nonisolated let results = AsyncStream<TranscriptionResult> { $0.finish() }
    var failBuffers = false
    var holdStop = false
    var holdConsume = false
    private(set) var consuming = false
    private var consumeWaiter: CheckedContinuation<Void, Never>?
    private(set) var stopping = false
    private var stopWaiter: CheckedContinuation<Void, Never>?

    func configure(failBuffers: Bool = false, holdStop: Bool = false, holdConsume: Bool = false) {
        self.failBuffers = failBuffers
        self.holdStop = holdStop
        self.holdConsume = holdConsume
    }
    func start() -> UUID { UUID() }
    func consume(_ buffer: AudioCaptureBuffer) async throws {
        consuming = true
        if holdConsume { await withCheckedContinuation { consumeWaiter = $0 } }
        if failBuffers { throw SpeechAnalyzerTranscriberError.notRunning }
    }
    func stop() async -> String {
        stopping = true
        if holdStop { await withCheckedContinuation { stopWaiter = $0 } }
        return ""
    }
    func releaseStop() {
        stopWaiter?.resume()
        stopWaiter = nil
    }
    func releaseConsume() {
        consumeWaiter?.resume()
        consumeWaiter = nil
        holdConsume = false
    }
    func cancel() { releaseStop() }
}
