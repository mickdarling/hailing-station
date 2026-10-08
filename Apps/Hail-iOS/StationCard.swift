// swiftlint:disable file_length
import AVFAudio
import HailCore
import Speech
import SwiftUI
import UIKit
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
        let controller = AmbientListeningController(
            requestPermission: requestMicrophonePermission,
            makeStreamer: { send in
                try await audioSession.activate()
                // Headphones keep their A2DP route only without voice processing (#343).
                let capture = try echoGuard.ambientCapture(mode: AmbientCaptureModeResolver.currentMode())
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
                Task { on ? await controller.turnOn(for: binding) : await controller.turnOff() }
            })) {
                Label("Ambient listening", systemImage: "ear")
                    .font(.headline)
            }
            .accessibilityIdentifier("station.ambient-toggle")
            Toggle("Mask mic while speaking", isOn: $masksDuringReplies)
                .font(.subheadline)
                .accessibilityHint("Sends silence while a reply plays, instead of relying on echo cancellation")
                .accessibilityIdentifier("station.ambient-mask-toggle")
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
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: binding) { _, current in
            Task { await controller.update(binding: current, scene: scene) }
        }
        .onChange(of: scenePhase) { _, _ in
            Task { await controller.update(binding: binding, scene: scene) }
        }
        .onDisappear {
            connections.ambientStreaming = false
            Task { await controller.destinationLost() }
        }
        .onAppear { echoGuard.masksDuringReplies = masksDuringReplies }
        .onChange(of: masksDuringReplies) { _, masks in echoGuard.masksDuringReplies = masks }
    }

    private var scene: AmbientScene {
        switch scenePhase {
        case .active: .active
        case .background: .background
        default: .inactive
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
        guard UIApplication.shared.applicationState != .active else { return }
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
    await withCheckedContinuation(isolation: nil) { continuation in
        AVAudioApplication.requestRecordPermission { @Sendable granted in
            continuation.resume(returning: granted)
        }
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
