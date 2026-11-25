import HailCore
import SwiftUI

// Compile the native button, begin(), consumer, visibility and playback restoration on the same SwiftUI state.
typealias TranscriptionLabView = StationTranscriptionView
typealias ConversationDestinationID = StationConversationDestinationID

struct TranscriptionResources {
    let capture: any AudioCapturing
    let transcriber: any Transcriber
}

@MainActor @Observable
final class MountedTalkProbe {
    var view: StationTranscriptionView?
    var press: (@MainActor () -> Void)?
    var buttonIsEnabled = false
}

// The Talk button uses .plain. Keep its native style and expose SwiftUI's actual trigger so tests can deliver
// two activations in one main-actor turn, independent of accessibility event dispatch or a subsequent redraw.
extension Button {
    @MainActor
    func buttonStyle(_ style: PlainButtonStyle) -> some View {
        buttonStyle(MountedTalkButtonStyle(plain: style))
    }
}

private struct MountedTalkButtonStyle: PrimitiveButtonStyle {
    let plain: PlainButtonStyle
    @Environment(MountedTalkProbe.self) private var probe
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        plain.makeBody(configuration: configuration)
            .onChange(of: isEnabled, initial: true) { _, enabled in
                probe.buttonIsEnabled = enabled
                probe.press = { configuration.trigger() }
            }
    }
}

private struct TalkMount: View {
    let talk: StationTranscriptionView
    @Environment(MountedTalkProbe.self) private var probe

    var body: some View {
        Color.clear.frame(height: 0).onAppear { probe.view = talk }
    }
}

extension EnvironmentValues {
    var stationCompactTalk: Bool { false }
}

struct PasteOffer {}
struct PasteRefusalHandling {}

enum StationPlatform {
    static let voiceOverRunning = false
    static func announce(_ text: String) {}
}

extension StationTranscriptionView {
    var attachedPaste: PastedDraft? { nil }
    var pasteControl: some View { TalkMount(talk: self) }
    func announceStatusUnlessQuiet(_ current: String) {}

    // StationCard's result and destination callbacks are excluded under SWIFT_PACKAGE.
    func receiveResult(_ result: TranscriptionResult) {
        guard result.utteranceID == activeUtteranceID else { return }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            if !text.isEmpty { finalText = [finalText, text].filter { !$0.isEmpty }.joined(separator: " ") }
            volatileText = ""
        } else {
            volatileText = text
        }
    }

    func noteDestinationChange(previous: ConversationDestinationID?, current: ConversationDestinationID?) {
        guard current != previous else { return }
        destinationGeneration = UUID()
        let invalidatedSend = pendingSendID != nil
        if let pendingDestinationID { Self.uncorrelatedDestinations.insert(pendingDestinationID) }
        clearPendingSend()
        if invalidatedSend || (!isStarting && !isRecording && !isFinalizing && !isInterrupting) { status = "Ready" }
    }

    // Synthetic authorization and injected session, microphone and transcriber keep the mounted button off hardware.
    func prepareCaptureAuthorization() async -> Bool { true }
    func markAudioReceived() { hasReceivedAudio = true }

    // StationCard's capture callbacks live in its app-only section.
    func takeCaptureExclusivity() {
        CapturePlaybackSuppression.liveness[captureOwnerID] = { [self] in
            isStarting || isRecording || isFinalizing || isInterrupting || startTask != nil
        }
        if ownsCaptureSuppression { onCaptureWillBegin?(captureOwnerID) }
        beginCaptureExclusivity()
    }

    func restorePlaybackAfterFinish() {
        if scenePhase == .active {
            isForcedTeardown = false
            endCaptureExclusivity(resumingPlayback: true)
        } else {
            onCaptureTeardownCompleted?(captureOwnerID)
            restorePlaybackIfRequestedAndReady()
        }
    }

    func prepareForcedFinish() async -> Bool {
        let pendingStart = startTask
        pendingStart?.cancel()
        await deactivateTalkRoute()
        await pendingStart?.value
        guard let interruptTask else { return false }
        await interruptTask.value
        return true
    }

    func startInterrupt(using action: @escaping @MainActor () async throws -> Void) {
        guard interruptTask == nil else { return }
        interruptTask = Task {
            await interruptTarget(using: action)
            interruptTask = nil
        }
    }
}
