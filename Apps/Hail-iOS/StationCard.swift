// swiftlint:disable file_length
import AVFAudio
import HailCore
import Speech
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#endif

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
                        replyFailureStatuses: playback.terminalReplyFailureStatuses,
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
            #if os(iOS)
            NavigationLink("Routing spike") { RoutingSpikeView() }
            #endif
        }
        .navigationTitle("Labs")
        .stationToolBackNavigation()
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
    let microphone = await StationPlatform.requestMicrophone()
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

    /// Tap-to-talk capture state for the diagnostics log (#234); nothing is recorded while logging is off.
    func tapToTalk(started: Bool) {
        diagnostics.record(.captureState, [.state: .token(started ? "tap_to_talk_start" : "tap_to_talk_end")])
    }

    /// A heal dropped `count` capture holds with no live capture behind them (#760): logged as a tap-to-talk end with
    /// reason `other` and the count, from the existing vocabulary, so older Macs still accept the batch.
    /// Static, taking the diagnostics weakly from its caller, so a reporter never keeps a closed scene alive (#763).
    static func logHeal(_ count: Int, to diagnostics: DeviceDiagnostics?) {
        guard count > 0, let diagnostics else { return }
        diagnostics.record(.captureState, [
            .state: .token("tap_to_talk_end"), .reason: .token("other"), .count: .integer(Int64(count))
        ])
    }

    /// Ambient listening (#203) appears only for a confirmed destination whose host advertises `stream_audio`.
    @ViewBuilder
    var ambientListeningSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let (binding, hostName) = ambientPresentation {
                AmbientListeningCard(
                    binding: binding, hostName: hostName,
                    connections: connections, audioSession: audioRoutes, playback: playback,
                    echoGuard: echoGuard, diagnostics: diagnostics
                )
                .onDisappear { Task { await reconcileAmbientDestination() } }
            }
            reconnectNotice
        }
        .onChange(of: connections.ambientController?.reconnect.notice) { _, _ in
            // Accept core's same-destination generation in background as well as foreground.
            if acceptAppliedAmbientRestore() { return }
            Task { await reconcileRememberedSelection() }
        }
    }

    private var ambientPresentation: (AmbientAudioBinding, String)? {
        ambientRestorePresentation.card(hostName: destination?.endpoint.name)
    }

    private var ambientRestorePresentation: AmbientRestorePresentation {
        let binding = destination.flatMap { connections.ambientBinding(host: $0.hostID, targetID: $0.target.id) }
        return AmbientRestorePresentation(controller: connections.ambientController, confirmedBinding: binding)
    }

    /// A reconnect outcome belongs to the root surface. It never retains a card, capture, or destination binding.
    @ViewBuilder
    private var reconnectNotice: some View {
        if let notice = ambientRestorePresentation.notice {
            VStack(alignment: .leading, spacing: 6) {
                Text(notice.text)
                if let action = ambientRestorePresentation.noticeAction {
                    Button(action.title) { performAmbientNoticeAction(action) }
                    .buttonStyle(.borderedProminent)
                }
            }
            .accessibilityIdentifier("station.ambient-reconnect-notice")
        }
    }
}

/// The toggle starts off on launch. It starts only in the foreground, keeps capture alive through the background
/// and guarded transport restore (#904), and stops on a real destination loss or the owner's off. Card disappearance
/// during recovery is not an owner stop. Replies play while it is on (#227) through
/// the capture's echo canceller, so the mic stays open and Mick can talk over them (#269). "Mask mic while
/// speaking" restores the #227 behaviour (silence to the host while a reply is audible) for A/B comparison.
/// With headphones as the output when listening starts, capture runs without voice processing so they keep their
/// route, and the mic is silenced while replies play (#343).
struct AmbientListeningCard: View {
    let binding: AmbientAudioBinding
    let hostName: String
    let playback: ReplyPlaybackController
    let echoGuard: AmbientReplyEchoGuard
    let connections: HostConnectionStore
    @State private var controller: AmbientListeningController
    @AppStorage("ambient.masksDuringReplies") private var masksDuringReplies = false
    @Environment(\.scenePhase) private var scenePhase

    init(
        binding: AmbientAudioBinding, hostName: String,
        connections: HostConnectionStore, audioSession: AudioRouteModel, playback: ReplyPlaybackController,
        echoGuard: AmbientReplyEchoGuard, diagnostics: DeviceDiagnostics
    ) {
        self.binding = binding
        self.hostName = hostName
        self.playback = playback
        self.echoGuard = echoGuard
        self.connections = connections
        let controller = connections.ambientController ?? AmbientListeningController(
            requestPermission: requestMicrophonePermission,
            makeStreamer: { send in
                try await audioSession.activate()
                // Headphones keep their A2DP route only without voice processing (#343).
                let capture = try echoGuard.ambientCapture(mode: StationPlatform.ambientCaptureMode)
                return AmbientAudioStreamer(capture: capture, send: send)
            },
            releaseSession: { await audioSession.deactivate() },
            send: { [weak connections] payload, binding in
                guard let connections else { throw HostConnectionFailure.notReady }
                try await connections.sendAudio(payload, to: binding)
            }
        )
        controller.diagnostics = diagnostics
        // From the controller, not a view update, so the flag stays right in the background (#282).
        controller.onListeningChange = { [weak connections] listening in connections?.ambientStreaming = listening }
        controller.onUnexpectedStop = { AmbientStopNotifier.post($0) }
        controller.reconnect.onNotice = AmbientStopNotifier.reconnected
        _controller = State(initialValue: controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { controller.isOn }, set: { on in
                if on { AmbientStopNotifier.requestAuthorization() }
                Task { on ? await controller.turnOn(for: binding) : await controller.turnOff() }
            })) {
                Label("Ambient listening", systemImage: "ear")
                    .font(.headline)
            }
            .disabled(currentBinding == nil && !controller.isOn)
            .accessibilityIdentifier("station.ambient-toggle")
            Toggle("Mask mic while speaking", isOn: $masksDuringReplies)
                .font(.subheadline)
                .accessibilityHint("Sends silence while a reply plays, instead of relying on echo cancellation")
                .accessibilityIdentifier("station.ambient-mask-toggle")
            OverheardSettingsView(connections: connections)
            if controller.isListening, playback.isReplyAudioOutputBusy {
                Label("Speaking", systemImage: "speaker.wave.2.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.blue, in: Capsule())
                    .accessibilityLabel(echoGuard.isMasking
                        ? "Speaking a reply: sending silence to \(hostName) until it finishes"
                        : "Speaking a reply: still listening, with echo cancellation")
                    .accessibilityIdentifier("station.ambient-speaking")
            } else if controller.isListening {
                Label("Listening", systemImage: "mic.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.red, in: Capsule())
                    .accessibilityLabel("Listening: sending microphone audio to \(hostName)")
                    .accessibilityIdentifier("station.ambient-listening")
            } else if let handoff = controller.handoff, case .movedAway = handoff {
                // Another device took listening over (#366): where it went, not an error, and one tap back.
                AmbientMovedAwayView(handoff: handoff) {
                    Task { await controller.turnOn(for: binding) }
                }
            } else if let paused = controller.pausedReason {
                // Another app has the microphone (#445): still on, and it resumes by itself.
                Label(paused, systemImage: "pause.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHint("Listening resumes when the other app releases the microphone")
                    .accessibilityIdentifier("station.ambient-paused")
            } else if let reason = controller.stopReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("station.ambient-stop-reason")
            } else {
                Text("Sends this room's audio to \(hostName) while Hailing Station is open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if controller.isListening, connections.ownerVoiceUnrecognized.contains(binding.hostID) {
                OwnerVoiceUnrecognizedView()
            }
            if controller.isListening, let media = connections.mediaMode[binding.hostID] {
                MediaModeStatusView(status: media)
            }
            // The privacy switch (#735 S-6): while listening on a host that takes it, and while privacy is confirmed
            // on but the host stopped listening, so it can be turned off.
            if connections.showsPrivacySwitch(binding.hostID, listening: controller.isListening) {
                PrivacySwitchView(connections: connections, hostID: binding.hostID,
                                  listening: controller.isListening)
            }
            if controller.isListening, let handoff = controller.handoff, case .movedHere = handoff {
                // This device took listening over (#366): a brief, calm confirmation.
                Label(handoff.status, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
                    .transition(.opacity)
                    .accessibilityLabel(handoff.accessibilityLabel)
                    .accessibilityIdentifier("station.ambient-moved-here")
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controller.handoff)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: currentBinding) { _, _ in
            Task { await controller.update(binding: currentBinding, scene: scene) }
        }
        .onChange(of: scenePhase) { _, _ in
            Task { await controller.update(binding: currentBinding, scene: scene) }
        }
        .onAppear {
            connections.ambientController = controller
            Task { await controller.update(binding: currentBinding, scene: scene) }
            connections.onAmbientMovedHere = { [controller] host, from in controller.movedHere(from: from, host: host) }
        }
        .onAppear { echoGuard.masksDuringReplies = masksDuringReplies }
        .onChange(of: masksDuringReplies) { _, masks in echoGuard.masksDuringReplies = masks }
        .modifier(StationMenuListeningPublisher(controller: controller, binding: binding))
    }

    private var scene: AmbientScene {
        switch scenePhase {
        case .active: .active
        case .background: .background
        default: .inactive
        }
    }
}

extension AmbientListeningCard {
    /// Only pending recovery keeps the card through an unavailable destination. A notice has no capture lifetime.
    /// Only a current confirmed binding can resume.
    private var currentBinding: AmbientAudioBinding? {
        AmbientRestorePresentation(controller: controller, confirmedBinding:
            connections.ambientBinding(host: binding.hostID, targetID: binding.targetID)).resumeBinding
    }
}

/// RightyO does not recognise the owner's voice on this input (rightyo#164): say so, instead of owner-only features
/// failing silently, and point to enrolment on this mic. It clears by itself once the voice is recognised.
struct OwnerVoiceUnrecognizedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Your voice isn't recognised on this mic", systemImage: "person.crop.circle.badge.questionmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Stop confirmations, voice mute and Just me need it. Enroll your voice on this input: see RightyO's "
                + "docs/speaker-enrollment.md, \u{201C}A new microphone or input\u{201D}.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("station.ambient-owner-voice")
    }
}

/// The privacy switch and indicator (#735 S-6). It shows what the host confirmed, never the tap: PRIVATE only once the
/// host's notice says so on this live connection; anything unconfirmed (no notice yet, a tap waiting for its notice,
/// a connection that dropped) reads "Recording may be on". Re-checked each second, so a tap that is never answered
/// stops waiting and a lapsed notice stops counting.
struct PrivacySwitchView: View {
    let connections: HostConnectionStore
    let hostID: HostEndpoint.Identifier
    let listening: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = connections.privacySwitch(hostID, listening: listening, now: context.date)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { status.isPrivate }, set: { on in
                    Task { try? await connections.setPrivacy(on: on, host: hostID) }
                })) {
                    Label(status.title, systemImage: status.isPrivate ? "lock.fill" : "mic.fill")
                        .accessibilityIdentifier(status.shown == .privateListeningUnavailable
                            ? "station.privacy-unavailable" : "station.privacy-title")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(status.isPrivate ? Color.green : Color.orange)
                }
                .disabled(status.pending)
                .accessibilityLabel("Privacy")
                .accessibilityValue(status.title)
                .accessibilityHint("Turns privacy on or off on the Mac. It shows private only once the Mac confirms.")
                .accessibilityIdentifier("station.privacy-switch")
                HStack(spacing: 6) {
                    if status.pending {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityIdentifier("station.privacy-pending")
                    }
                    Text(status.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("station.privacy-status")
            }
        }
    }
}

/// The owner's spoken media mode (#612): while it is on, replies stop because RightyO hears only the assistant's
/// name, so the card says so and how it ends. Read-only: whether the device may turn it off is Mick's call.
struct MediaModeStatusView: View {
    let status: MediaModeStatus

    var body: some View {
        // Re-checked each minute, so a mode past its end stops showing even if the host's "off" never arrives.
        TimelineView(.everyMinute) { context in
            if let detail = status.detail(now: context.date) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Media mode is on", systemImage: "tv")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.indigo)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("station.ambient-media-mode")
            }
        }
    }
}

/// Ambient listening moved to another device (#366). Calm and glanceable from across the room: which device has
/// it now, and one large "Listen here" that starts listening on this device, the same take-over in reverse. Side by
/// side when there is room, stacked on a narrow card.
struct AmbientMovedAwayView: View {
    let handoff: AmbientHandoff
    let listenHere: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                status
                Spacer(minLength: 8)
                button
            }
            VStack(alignment: .leading, spacing: 12) {
                status
                button
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("station.ambient-moved")
    }

    private var status: some View {
        Label {
            Text(handoff.status)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(handoff.accessibilityLabel)
        .accessibilityIdentifier("station.ambient-moved-status")
    }

    private var button: some View {
        Button(action: listenHere) {
            Label(AmbientHandoff.listenHereTitle, systemImage: "ear")
                .font(.headline)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint("Starts ambient listening on this device")
        .accessibilityIdentifier("station.ambient-listen-here")
    }

    /// The device that has listening now, by class only.
    private var symbol: String {
        guard case .movedAway(let kind) = handoff else { return "arrow.right.circle" }
        switch kind {
        case "pad": return "ipad.landscape"
        case "phone": return "iphone"
        case "mac": return "laptopcomputer"
        default: return "arrow.right.circle"
        }
    }
}

/// Tells Mick when ambient listening stops while another app is in front (#287): a banner with the reason and
/// the default sound. In the foreground the card already shows the reason, so nothing is posted.
@MainActor
enum AmbientStopNotifier {
    #if os(iOS)
    private static var lastHapticNotice: UUID?
    #endif
    static func reconnected(_ notice: AmbientListeningReconnect.Notice) {
        #if os(iOS)
        // A late refusal replaces this outcome; it must not produce a second haptic for the same drop.
        if lastHapticNotice != notice.id {
            lastHapticNotice = notice.id
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        #endif
        StationPlatform.announce(notice.text)
        post(notice.text, title: notice.notificationTitle)
    }

    static func requestAuthorization() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    static func post(_ reason: String, title: String = "Hailing Station stopped listening") {
        guard !StationPlatform.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = reason
        content.sound = .default
        let request = UNNotificationRequest(identifier: "ambient-stop", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// The "Diagnostics logging" switch (#234). Off by default and remembered. Off records and sends nothing and
/// clears what was kept; on keeps a short event log (never audio or words) and sends it only to a Mac whose
/// haild runs with `--device-diagnostics`.
struct DiagnosticsLoggingCard: View {
    let diagnostics: DeviceDiagnostics
    let collectingHost: HostConnectionSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { diagnostics.isEnabled }, set: { diagnostics.setEnabled($0) })) {
                Label("Diagnostics logging", systemImage: "list.bullet.rectangle")
                    .font(.headline)
            }
            .accessibilityIdentifier("station.diagnostics-toggle")
            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("station.diagnostics-status")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var explanation: String {
        guard diagnostics.isEnabled else {
            return "Off. Nothing is recorded or sent. When on, connection and audio events (never audio or words) "
                + "go to a Mac that collects them, to help find why listening stopped."
        }
        guard let collectingHost else {
            return "On, but no connected Mac is collecting. Start haild with --device-diagnostics. "
                + "Keeping the last \(diagnostics.bufferedCount) events here until one does."
        }
        return "On. Sending connection and audio events (never audio or words) to \(collectingHost.endpoint.name)."
    }
}

/// TCC invokes the callback on an arbitrary queue, so this bridge must not inherit the view's MainActor.
private func requestMicrophonePermission() async -> Bool {
    await StationPlatform.requestMicrophone()
}

extension TranscriptionLabView {
    /// Takes capture suppression for a new capture (#91), registering whether it is live (#760). An owner still
    /// holding from an earlier teardown re-arms it, in case a heal dropped that hold meanwhile.
    @MainActor
    func takeCaptureExclusivity() {
        CapturePlaybackSuppression.liveness[captureOwnerID] = { [self] in
            isStarting || isRecording || isFinalizing || isInterrupting || startTask != nil
        }
        if ownsCaptureSuppression { onCaptureWillBegin?(captureOwnerID) }
        beginCaptureExclusivity()
    }
}

@MainActor
enum StationUITestReset {
    static var didRun = false
}
