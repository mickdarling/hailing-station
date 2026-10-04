// swiftlint:disable file_length
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

    /// Ambient listening (#203) appears only for a confirmed destination whose host advertises `stream_audio`.
    @ViewBuilder
    var ambientListeningSurface: some View {
        if let destination,
           let binding = connections.ambientBinding(host: destination.hostID, targetID: destination.target.id) {
            AmbientListeningCard(
                binding: binding, hostName: destination.endpoint.name,
                connections: connections, audioSession: audioRoutes, playback: playback
            )
        }
    }
}

/// The toggle starts off whenever the card appears, stops when the scene leaves `.active`, when the binding
/// changes and when the card goes away, and never restarts by itself. Replies play while it is on (#227); the
/// echo guard sends silence to the host while one is audible, and the card says "Speaking" meanwhile.
struct AmbientListeningCard: View {
    let binding: AmbientAudioBinding
    let hostName: String
    let playback: ReplyPlaybackController
    @State private var controller: AmbientListeningController
    @State private var echoGuard: AmbientReplyEchoGuard
    @Environment(\.scenePhase) private var scenePhase

    init(
        binding: AmbientAudioBinding, hostName: String,
        connections: HostConnectionStore, audioSession: AudioRouteModel, playback: ReplyPlaybackController
    ) {
        self.binding = binding
        self.hostName = hostName
        self.playback = playback
        // State keeps the first guard and controller, so the controller's streamers always use the followed guard.
        let echoGuard = AmbientReplyEchoGuard()
        _echoGuard = State(initialValue: echoGuard)
        _controller = State(initialValue: AmbientListeningController(
            requestPermission: requestMicrophonePermission,
            makeStreamer: { send in
                try await audioSession.activate()
                let streamer = AmbientAudioStreamer(
                    capture: try AmbientAudioStreamer.voiceProcessingCapture(), send: send
                )
                streamer.echoGuard = echoGuard
                return streamer
            },
            releaseSession: { await audioSession.deactivate() },
            send: { [connections] payload, binding in try await connections.sendAudio(payload, to: binding) }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { controller.isOn }, set: { on in
                Task { on ? await controller.turnOn(for: binding) : await controller.turnOff() }
            })) {
                Label("Ambient listening", systemImage: "ear")
                    .font(.headline)
            }
            .accessibilityIdentifier("station.ambient-toggle")
            if controller.isListening, playback.isReplyAudioOutputBusy {
                Label("Speaking", systemImage: "speaker.wave.2.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.blue, in: Capsule())
                    .accessibilityLabel("Speaking a reply: sending silence to \(hostName) until it finishes")
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
        .onAppear { echoGuard.follow(playback) }
        .onDisappear { Task { await controller.turnOff() } }
    }

    private var scene: AmbientScene {
        switch scenePhase {
        case .active: .active
        case .background: .background
        default: .inactive
        }
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
