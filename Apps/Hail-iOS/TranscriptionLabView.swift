import HailCore
import SwiftUI

enum TalkCardStatus: Equatable {
    case activity(String), notSent(TalkSendRefusal)

    var message: String {
        switch self {
        case .activity(let text): text
        case .notSent(let reason): reason.message
        }
    }
}

/// Audio-first capture surface shared by compact and regular-width station layouts.
#if !SWIFT_PACKAGE
typealias ConversationDestinationID = StationConversationDestinationID
typealias TranscriptionLabView = StationTranscriptionView
#endif

struct StationTranscriptionView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let destinationLabel: String?
    let destinationID: StationConversationDestinationID?
    let route: StationTalkRoute?
    var selectedBinding: TalkDestinationBinding? { route?.binding(for: destinationID) }
    let replyIDs: Set<String>
    let replyPlaybackStatus: String?
    let selectedReplyID: String?
    private let replyAudioIsBusy: @MainActor () -> Bool
    var globalReplyAudioSpeaking: Bool { replyAudioIsBusy() }
    let controlledReplyPlaybackStatus: String?
    let replyFailureStatuses: [String: String]
    let onCaptureWillBegin: (@MainActor (UUID) -> Void)?
    let onCaptureDidEnd: (@MainActor (UUID, _ resumingPlayback: Bool) -> Void)?
    let onCaptureTeardownCompleted: (@MainActor (UUID) -> Void)?
    let onFinalized: (@MainActor (String, PastedDraft?) async throws -> Void)?
    /// Whether the destination takes pasted text, and the latest paste its Mac refused (#608).
    let pasteOffer: PasteOffer
    let onEscape: (@MainActor () async throws -> Void)?
    @WindowTalk var talkSession
    @Environment(HostConnectionStore.self) private var connections: HostConnectionStore?
    var capture: any AudioCapturing { talkSession.resources.capture }
    var transcriber: any Transcriber { talkSession.resources.transcriber }
    @State var isRecording = false
    @State var finalText = ""
    @State var volatileText = ""
    @State var talkStatus = TalkCardStatus.activity("Ready")
    var status: String {
        get { talkStatus.message }
        nonmutating set { talkStatus = .activity(newValue) }
    }
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
    @State var recordingDestination: TalkDestinationBinding?
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
        route: StationTalkRoute? = nil,
        replyIDs: Set<String> = [],
        replyPlaybackStatus: String? = nil,
        selectedReplyID: String? = nil,
        globalReplyAudioSpeaking: @autoclosure @escaping @MainActor () -> Bool = false,
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
        self.route = route
        self.replyIDs = replyIDs
        self.replyPlaybackStatus = replyPlaybackStatus
        self.selectedReplyID = selectedReplyID
        self.replyAudioIsBusy = globalReplyAudioSpeaking
        self.controlledReplyPlaybackStatus = controlledReplyPlaybackStatus
        self.replyFailureStatuses = replyFailureStatuses
        self.onCaptureWillBegin = onCaptureWillBegin
        self.onCaptureDidEnd = onCaptureDidEnd
        self.onCaptureTeardownCompleted = onCaptureTeardownCompleted
        (self.onFinalized, self.onEscape) = (onFinalized, onEscape)
        self.pasteOffer = pasteOffer
    }
    func deactivateTalkRoute() async {
        guard !(connections?.ambientController?.isOn ?? false) else { return }
        await audioSession.deactivate()
    }
}
extension StationTranscriptionView {
    var body: some View {
        VStack(spacing: compactTalk ? 10 : 18) {
            // The conversation thread shows each request as You (#318), so no separate last-request panel (#429).
            if !compactTalk, let destinationLabel {
                Label(destinationLabel, systemImage: "desktopcomputer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Full screen (#819), one row: talk, its status and Escape. The button keeps the first slot either way,
            // so expanding never rebuilds it.
            let row = compactTalk ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 18))
            row {
                talkButton.disabled(talkSession.owner.map { $0 != captureOwnerID } ?? false)
                if compactTalk { statusRow; escapeControl }
            }

            // Below the button, so its appearing never moves Tap to talk under a finishing tap.
            if talkStatus == .notSent(.destinationChanged) {
                Text(finalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else { liveTranscript }
            // Always mounted (#819 review), so a destination change still clears a paste and a refused one comes
            // back. Full screen it hides only the bare Paste button: an attached paste or a problem still shows.
            pasteControl.stationCollapsed(compactTalk && attachedPaste == nil && pasteProblem == nil)

            if !compactTalk { escapeControl; statusRow }
        }
        .padding(compactTalk ? 12 : 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .navigationTitle("Conversation")
        .onAppear { restorePlaybackAfterForcedTeardown() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restorePlaybackAfterForcedTeardown(); announceDeferredStatusIfNeeded() }
        }
        .onChange(of: replyIDs, noteReplyArrival)
        .onChange(of: status) { _, current in announceStatusUnlessQuiet(current) }
        .onChange(of: ownsCaptureSuppression) { wasSuppressed, isSuppressed in
            if wasSuppressed && !isSuppressed { announceDeferredStatusIfNeeded() }
        }
        .onChange(of: [selectedReplyID, replyPlaybackStatus]) { announceReplyStatusIfNeeded(replyPlaybackStatus) }
        .onChange(of: controlledReplyPlaybackStatus) { _, current in announceControlledReplyFailureIfNeeded(current) }
        .onChange(of: replyFailureStatuses, announceNewReplyFailures)
        .onChange(of: globalReplyAudioSpeaking) { wasSpeaking, isSpeaking in
            if wasSpeaking && !isSpeaking { announceDeferredStatusIfNeeded() }
        }
        .onChange(of: destinationID) { old, new in
            if talkStatus != .notSent(.destinationChanged) { noteDestinationChange(previous: old, current: new) }
        }
        .onDisappear {
            if let pendingDestinationID { Self.uncorrelatedDestinations.insert(pendingDestinationID) }
            clearPendingSend()
            startTask?.cancel()
            Task { await finishOnDisappear() }
        }
    }
}
