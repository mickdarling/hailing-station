import AVFAudio
import HailCore
import Speech
import SwiftUI

extension View {
    func stationCard(minHeight: CGFloat = 320) -> some View {
        frame(maxWidth: .infinity, minHeight: minHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct CaptureSafeLabsView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let playback: ReplyPlaybackController

    var body: some View {
        List {
            NavigationLink("Live transcription") {
                if #available(iOS 26.0, *) {
                    TranscriptionLabView(
                        audioSession: audioSession,
                        globalReplyAudioSpeaking: playback.isReplyAudioOutputBusy,
                        controlledReplyPlaybackStatus: playback.statusForControls,
                        onCaptureWillBegin: { CapturePlaybackSuppression.begin($0, using: playback) },
                        onCaptureDidEnd: {
                            CapturePlaybackSuppression.end($0, using: playback, resuming: $1)
                        },
                        onCaptureTeardownCompleted: {
                            CapturePlaybackSuppression.markCleanupComplete($0, using: playback)
                        }
                    )
                }
            }
            NavigationLink("Routing spike") { RoutingSpikeView() }
        }
        .navigationTitle("Labs")
    }
}

extension TranscriptionLabView {
    @MainActor
    func startInterrupt(using action: @escaping @MainActor () async throws -> Void) {
        guard interruptTask == nil else { return }
        interruptTask = Task {
            await interruptTarget(using: action)
            interruptTask = nil
        }
    }

    @MainActor
    func prepareCaptureAuthorization() async -> Bool {
        status = "Requesting microphone and speech access…"
        guard await requestHailPermissions() else {
            status = "Microphone and speech recognition permissions are required."
            releaseCaptureExclusivityAfterWork()
            return false
        }
        return true
    }

    @MainActor
    func prepareForcedFinish() async -> Bool {
        let pendingStart = startTask
        pendingStart?.cancel()
        await audioSession.deactivate()
        await pendingStart?.value
        guard let pendingInterrupt = interruptTask else { return false }
        await pendingInterrupt.value
        return true
    }

    @MainActor
    func completeFinish(generation: UUID) {
        guard finishGeneration == generation else { return }
        finishGeneration = nil
        finishTask = nil
        if scenePhase == .active {
            isForcedTeardown = false
            endCaptureExclusivity(resumingPlayback: true)
        } else {
            onCaptureTeardownCompleted?(captureOwnerID)
            restorePlaybackIfRequestedAndReady()
        }
    }

    func markAudioReceived() {
        guard !hasReceivedAudio else { return }
        hasReceivedAudio = true
        status = "Receiving audio"
    }

    @MainActor
    func observeResults() async {
        let coordinator = audioSession as? any AudioSceneCleanupCoordinating
        coordinator?.installSceneCleanup { await finish(force: true) }
        defer { coordinator?.removeSceneCleanup() }
        for await result in transcriber.results {
            guard result.utteranceID == activeUtteranceID else { continue }
            if result.isFinal {
                appendFinal(result.text)
                volatileText = ""
            } else {
                volatileText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    func appendFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finalText = [finalText, trimmed].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// TCC invokes these callbacks on arbitrary queues, so this bridge must not inherit the view's MainActor.
private func requestHailPermissions() async -> Bool {
    let microphone = await withCheckedContinuation(isolation: nil) { continuation in
        AVAudioApplication.requestRecordPermission { @Sendable granted in
            continuation.resume(returning: granted)
        }
    }
    guard microphone else { return false }

    return await withCheckedContinuation(isolation: nil) { continuation in
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            continuation.resume(returning: status == .authorized)
        }
    }
}

extension RootView {
    var hasReadyHost: Bool {
        connections.hosts.contains(where: { $0.state == .ready })
    }
}

@MainActor
enum CapturePlaybackSuppression {
    private struct Entry {
        var cleanupComplete = false
    }

    private static var entries: [ObjectIdentifier: [UUID: Entry]] = [:]

    static func begin(_ owner: UUID, using playback: ReplyPlaybackController) {
        let key = ObjectIdentifier(playback)
        let wasEmpty = entries[key]?.isEmpty != false
        entries[key, default: [:]][owner] = Entry()
        if wasEmpty { playback.beginCaptureSuppression() }
    }

    static func end(_ owner: UUID, using playback: ReplyPlaybackController, resuming: Bool) {
        let key = ObjectIdentifier(playback)
        guard entries[key]?.removeValue(forKey: owner) != nil else { return }
        guard entries[key]?.isEmpty == true else { return }
        entries[key] = nil
        playback.endCaptureSuppression(resumingPlayback: resuming)
    }

    static func markCleanupComplete(_ owner: UUID, using playback: ReplyPlaybackController) {
        let key = ObjectIdentifier(playback)
        guard entries[key]?[owner] != nil else { return }
        entries[key]?[owner]?.cleanupComplete = true
    }

    static func releaseCompleted(using playback: ReplyPlaybackController) {
        let key = ObjectIdentifier(playback)
        let completed = entries[key]?.compactMap { owner, entry in
            entry.cleanupComplete ? owner : nil
        } ?? []
        for owner in completed {
            end(owner, using: playback, resuming: true)
        }
    }
}

@MainActor
enum StationUITestReset {
    static var didRun = false
}
