import HailCore
import SwiftUI

// Only the Talk presentation can read this window dependency. Route tools receive AudioRouteModel.
private extension EnvironmentValues {
    @Entry var windowTalkSession: StationTalkSession?
}

extension View {
    func sharingTalkSession(_ session: StationTalkSession) -> some View {
        environment(\.windowTalkSession, session)
    }
}

struct SelectedReplyPlaybackObservation: Equatable {
    let id: String?
    let status: String?
}

/// Audio-first capture surface shared by compact and regular-width station layouts.
#if !SWIFT_PACKAGE
typealias ConversationDestinationID = StationConversationDestinationID
typealias TranscriptionLabView = StationTranscriptionView
#endif

struct StationDockControls {
    let destination: () -> DestinationControlState
    let privacy: (() -> Void)?
    let listening: () -> Void
    let routes: () -> Void
}

struct StationTranscriptionView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let destinationLabel: String?
    let destinationID: StationConversationDestinationID?
    let selectedDestination: @MainActor () -> StationConversationDestinationID.Connection?
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
    @Environment(\.windowTalkSession) private var windowTalk
    var talkSession: StationTalkSession {
        guard let windowTalk else { preconditionFailure("Talk requires its window’s session") }
        return windowTalk
    }
    var capture: any AudioCapturing { talkSession.resources.capture }
    var transcriber: any Transcriber { talkSession.resources.transcriber }
    @State var isRecording = false
    @State var finalText = ""
    @State var volatileText = ""
    @State var talkStatus = StationTalkStatus.ready
    var status: String { talkStatus.text }
    @State var isStarting = false
    @State var isFinalizing = false
    @State var hasReceivedAudio = false
    @State var activeUtteranceID: UUID?
    @State var isInterrupting = false
    @State var interruptTask: Task<Void, Never>?
    @State var isForcedTeardown = false
    @State var captureOwnerID = UUID()
    @State var pendingSendID: UUID?
    @State var pendingDestinationID: StationConversationDestinationID?
    /// The send a reply arrival ended while it was still in flight (#636): a placed reply can beat its request's send,
    /// so if that send then fails, its failure still shows rather than the arrival's "Reply received".
    @State var answeredSendID: UUID?
    @State var destinationGeneration = UUID()
    @State var recordingDestination: StationConversationDestinationID.Connection?
    @State var recordingGeneration: UUID?
    @State var replyTimeoutTask: Task<Void, Never>?
    @State var ownsCaptureSuppression = false
    /// Only what must stay reachable while the conversation is full screen (#819); the station sets it, Labs never.
    @Environment(\.stationCompactTalk) var compactTalk
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
    @State var pastes = PasteHandoff()
    @State var pasteProblem: String?
    @State var pasteRefusalHandling = PasteRefusalHandling()
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    init(
        audioSession: any AudioSessionDiagnosticsProviding,
        destinationLabel: String? = nil,
        destinationID: StationConversationDestinationID? = nil,
        selectedDestination: @escaping @MainActor () -> StationConversationDestinationID.Connection? = { nil },
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
        self.selectedDestination = selectedDestination
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
    }

    /// Presentation only. The same installed owner supplies capture, paste and lifecycle callbacks in either layout.
    var dock: StationDockControls?
    @State var showingDockPaste = false

    var body: some View {
        Group {
            if let dock { stationDock(dock) } else { card }
        }
        .navigationTitle("Conversation")
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

extension StationTranscriptionView {
    var selectedReplyPlaybackObservation: SelectedReplyPlaybackObservation {
        SelectedReplyPlaybackObservation(id: selectedReplyID, status: replyPlaybackStatus)
    }
}
