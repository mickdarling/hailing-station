import AVFAudio
import HailCore
import Speech
import SwiftUI

struct ConversationDestinationID: Hashable {
    let endpointID: HostEndpoint.Identifier
    let targetID: String
}

struct SelectedReplyPlaybackObservation: Equatable {
    let id: String?
    let status: String?
}

/// Audio-first capture surface shared by compact and regular-width station layouts.
struct TranscriptionLabView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let destinationLabel: String?
    let destinationID: ConversationDestinationID?
    let replyIDs: Set<String>
    let replyPlaybackStatus: String?
    let selectedReplyID: String?
    let globalReplyAudioSpeaking: Bool
    let controlledReplyPlaybackStatus: String?
    let replyFailureStatuses: [String: String]
    let onCaptureWillBegin: (@MainActor (UUID) -> Void)?
    let onCaptureDidEnd: (@MainActor (UUID, _ resumingPlayback: Bool) -> Void)?
    let onCaptureTeardownCompleted: (@MainActor (UUID) -> Void)?
    /// Sends the spoken request, with the attached paste when there is one (#608).
    let onFinalized: (@MainActor (String, PastedDraft?) async throws -> Void)?
    /// Whether the destination takes pasted text, and the latest paste its Mac refused (#608).
    let pasteOffer: PasteOffer
    let onEscape: (@MainActor () async throws -> Void)?

    @State var capture: any AudioCapturing
    @State var transcriber: any Transcriber
    @State var isRecording = false
    @State var finalText = ""
    @State var volatileText = ""
    @State var status = "Ready"
    @State var isStarting = false
    @State var isFinalizing = false
    @State var hasReceivedAudio = false
    @State var activeUtteranceID: UUID?
    @State var isInterrupting = false
    @State var interruptTask: Task<Void, Never>?
    @State var isForcedTeardown = false
    @State var captureOwnerID = UUID()
    @State var pendingSendID: UUID?
    @State var pendingDestinationID: ConversationDestinationID?
    /// The send a reply arrival ended while it was still in flight (#636): a placed reply can beat its request's send,
    /// so if that send then fails, its failure still shows rather than the arrival's "Reply received".
    @State var answeredSendID: UUID?
    @State var destinationGeneration = UUID()
    @State var replyTimeoutTask: Task<Void, Never>?
    @State var ownsCaptureSuppression = false
    @State var deferredStatusAnnouncement: String?
    @State var deferredReplyAnnouncement: String?
    @State var deferredControlledReplyFailure: String?
    @State var deferredReplyFailures: [String: String] = [:]
    @State var deferredReplayNotice: String?
    @State var playbackRestoreRequested = false
    @State var startTask: Task<Void, Never>?
    @State var finishTask: Task<Void, Never>?
    @State var finishGeneration: UUID?
    @State var bufferTask: Task<Void, Never>?
    /// Text pasted to go with the next request, or on its own (#608); never read from the clipboard without a tap.
    @State var attachedPaste: PastedDraft?
    @State var pasteProblem: String?
    @State var pasteRefusalHandling = PasteRefusalHandling()
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    init(
        audioSession: any AudioSessionDiagnosticsProviding,
        capture: any AudioCapturing = AVAudioEngineCapture(),
        transcriber: (any Transcriber)? = nil,
        destinationLabel: String? = nil,
        destinationID: ConversationDestinationID? = nil,
        replyIDs: Set<String> = [],
        replyPlaybackStatus: String? = nil,
        selectedReplyID: String? = nil,
        globalReplyAudioSpeaking: Bool = false,
        controlledReplyPlaybackStatus: String? = nil,
        replyFailureStatuses: [String: String] = [:],
        onCaptureWillBegin: (@MainActor (UUID) -> Void)? = nil,
        onCaptureDidEnd: (@MainActor (UUID, _ resumingPlayback: Bool) -> Void)? = nil,
        onCaptureTeardownCompleted: (@MainActor (UUID) -> Void)? = nil,
        onFinalized: (@MainActor (String, PastedDraft?) async throws -> Void)? = nil,
        pasteOffer: PasteOffer = PasteOffer(),
        onEscape: (@MainActor () async throws -> Void)? = nil
    ) {
        self.audioSession = audioSession
        self.destinationLabel = destinationLabel
        self.destinationID = destinationID
        self.replyIDs = replyIDs
        self.replyPlaybackStatus = replyPlaybackStatus
        self.selectedReplyID = selectedReplyID
        self.globalReplyAudioSpeaking = globalReplyAudioSpeaking
        self.controlledReplyPlaybackStatus = controlledReplyPlaybackStatus
        self.replyFailureStatuses = replyFailureStatuses
        self.onCaptureWillBegin = onCaptureWillBegin
        self.onCaptureDidEnd = onCaptureDidEnd
        self.onCaptureTeardownCompleted = onCaptureTeardownCompleted
        (self.onFinalized, self.onEscape) = (onFinalized, onEscape)
        self.pasteOffer = pasteOffer
        _capture = State(initialValue: capture)
        _transcriber = State(initialValue: transcriber ?? Self.defaultTranscriber())
    }

    var body: some View {
        VStack(spacing: 18) {
            // The conversation thread shows each request as You (#318), so no separate last-request panel (#429).
            if let destinationLabel {
                Label(destinationLabel, systemImage: "desktopcomputer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            talkButton

            // Below the button, so its appearing never moves Tap to talk under a finishing tap.
            liveTranscript

            pasteControl

            if let onEscape {
                Button(role: .destructive) {
                    startInterrupt(using: onEscape)
                } label: {
                    Label("Escape", systemImage: "xmark.octagon.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isFinalizing || finishTask != nil || interruptTask != nil)
                .accessibilityHint("Discards any active recording and sends Escape immediately to the target.")
            }

            statusRow
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .navigationTitle("Conversation")
        .task { await observeResults() }
        .onAppear { restorePlaybackAfterForcedTeardown() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restorePlaybackAfterForcedTeardown(); announceDeferredStatusIfNeeded() }
        }
        .onChange(of: replyIDs) { previous, current in
            noteReplyArrival(previous: previous, current: current)
        }
        .onChange(of: status) { _, current in
            announceStatusUnlessQuiet(current)
        }
        .onChange(of: ownsCaptureSuppression) { wasSuppressed, isSuppressed in
            if wasSuppressed && !isSuppressed { announceDeferredStatusIfNeeded() }
        }
        .onChange(of: selectedReplyPlaybackObservation) { _, current in
            announceReplyStatusIfNeeded(current.status)
        }
        .onChange(of: controlledReplyPlaybackStatus) { _, current in
            announceControlledReplyFailureIfNeeded(current)
        }
        .onChange(of: replyFailureStatuses) { previous, current in
            announceNewReplyFailures(previous: previous, current: current)
        }
        .onChange(of: globalReplyAudioSpeaking) { wasSpeaking, isSpeaking in
            if wasSpeaking && !isSpeaking { announceDeferredStatusIfNeeded() }
        }
        .onChange(of: destinationID) { previous, current in
            noteDestinationChange(previous: previous, current: current)
        }
        .onDisappear {
            if let pendingDestinationID { Self.uncorrelatedDestinations.insert(pendingDestinationID) }
            clearPendingSend()
            startTask?.cancel()
            Task { await finish(force: true) }
        }
    }
}

extension TranscriptionLabView {
    var selectedReplyPlaybackObservation: SelectedReplyPlaybackObservation {
        SelectedReplyPlaybackObservation(id: selectedReplyID, status: replyPlaybackStatus)
    }

    private static func defaultTranscriber() -> any Transcriber {
        if #available(iOS 26.0, macOS 26.0, *) { return SpeechAnalyzerTranscriber() }
        return SFSpeechRecognizerTranscriber()
    }
}
