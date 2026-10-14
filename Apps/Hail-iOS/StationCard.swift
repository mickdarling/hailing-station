// swiftlint:disable file_length
import AVFAudio
import HailCore
import Speech
import SwiftUI
#if os(iOS)
import UIKit
#endif
import UserNotifications

extension View {
    func stationCard(minHeight: CGFloat = 320) -> some View {
        frame(maxWidth: .infinity, minHeight: minHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct CaptureSafeLabsView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let playback: ReplyPlaybackController
    var mayBeginCapture: @MainActor () -> Bool = { true }
    var captureRequested: @MainActor (UUID) -> Void = { _ in }
    var captureReleased: @MainActor (UUID) -> Void = { _ in }

    var body: some View {
        List {
            NavigationLink("Live transcription") {
                if #available(iOS 26.0, *) {
                    TranscriptionLabView(
                        audioSession: audioSession,
                        mayBeginCapture: mayBeginCapture,
                        globalReplyAudioSpeaking: playback.isReplyAudioOutputBusy,
                        controlledReplyPlaybackStatus: playback.statusForControls,
                        replyFailureStatuses: playback.terminalReplyFailureStatuses,
                        onCaptureWillBegin: {
                            captureRequested($0)
                            CapturePlaybackSuppression.begin($0, using: playback)
                        },
                        onCaptureDidEnd: {
                            captureReleased($0)
                            CapturePlaybackSuppression.end($0, using: playback, resuming: $1)
                        },
                        onCaptureTeardownCompleted: {
                            captureReleased($0)
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
        let admitted = await CapturePermissionAdmission.request(
            mayBegin: mayBeginCapture, reserve: { beginCaptureExclusivity() },
            permissions: { await requestHailPermissions() }, release: { releaseCaptureExclusivityAfterWork() }
        )
        guard admitted else {
            status = Task.isCancelled ? "Ready" : "Microphone and speech recognition permissions are required."
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

    /// Ambient listening (#203) appears only for a confirmed destination whose host advertises `stream_audio`.
    @ViewBuilder
    var ambientListeningSurface: some View {
        if let destination,
           let binding = connections.ambientBinding(host: destination.hostID, targetID: destination.target.id) {
            AmbientListeningCard(
                binding: binding, hostName: destination.endpoint.name,
                connections: connections, audioSession: audioRoutes, playback: playback,
                echoGuard: echoGuard, diagnostics: diagnostics
            )
        }
    }
}

/// The toggle starts off whenever the card appears, stops when the scene leaves `.active`, when the binding
/// changes and when the card goes away, and never restarts by itself. Replies play while it is on (#227) through
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
    @State var controller: AmbientListeningController
    @AppStorage("ambient.masksDuringReplies") private var masksDuringReplies = false
    @Environment(\.scenePhase) var scenePhase
    #if os(macOS)
    @Environment(CoachingCaptureExclusion.self) var exclusion
    @State var captureReservation: UUID?
    @State var startup: Task<Void, Never>?
    #endif

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
        let controller = AmbientListeningController(
            requestPermission: requestMicrophonePermission,
            makeStreamer: { send in
                try await audioSession.activate()
                // Headphones keep their A2DP route only without voice processing (#343).
                let capture = try echoGuard.ambientCapture(mode: StationPlatform.captureMode)
                return AmbientAudioStreamer(capture: capture, send: send)
            },
            releaseSession: { await audioSession.deactivate() },
            send: { [connections] payload, binding in try await connections.sendAudio(payload, to: binding) }
        )
        controller.diagnostics = diagnostics
        // From the controller, not a view update, so the flag stays right in the background (#282).
        controller.onListeningChange = { [connections] listening in connections.ambientStreaming = listening }
        controller.onUnexpectedStop = { AmbientStopNotifier.post($0) }
        _controller = State(initialValue: controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { controller.isOn }, set: { on in
                if on { AmbientStopNotifier.requestAuthorization() }
                requestListening(on)
            })) {
                Label("Ambient listening", systemImage: "ear")
                    .font(.headline)
            }
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
                    requestListening(true)
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
        .onChange(of: binding) { _, current in
            updateListening(current)
        }
        .onChange(of: scenePhase) { _, _ in
            updateListening(binding)
        }
        .onAppear {
            connections.onAmbientMovedHere = { [controller] host, from in controller.movedHere(from: from, host: host) }
        }
        .onDisappear {
            connections.ambientStreaming = false
            connections.onAmbientMovedHere = nil
            closeListening()
        }
        .onAppear { echoGuard.masksDuringReplies = masksDuringReplies }
        .onChange(of: masksDuringReplies) { _, masks in echoGuard.masksDuringReplies = masks }
    }

    var scene: AmbientScene {
        switch scenePhase {
        case .active: .active
        case .background: .background
        default: .inactive
        }
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
    static func requestAuthorization() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    static func post(_ reason: String) {
        guard !StationPlatform.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Hailing Station stopped listening"
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
