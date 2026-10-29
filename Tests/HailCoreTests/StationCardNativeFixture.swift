import HailCore
import HailProtocol
import SwiftUI

/// Peripheral panels / notification effects are inert; the actual card's init, controls and lifecycle compile.
@MainActor
func makeNativeAmbientCard(rig: AmbientReconnectRig, diagnostics: DeviceDiagnostics) throws
    -> AmbientListeningCardContent {
    let audio = AudioRouteModel(controller: ManagedAudioSession(
        backend: FakeAudioSessionBackend(inputs: [.builtIn])))
    let content = AmbientListeningCardContent(
        binding: try rig.currentBinding(), hostName: rig.endpoint.name, connections: rig.store, audioSession: audio,
        playback: ReplyPlaybackController(player: StationLifecyclePlayer()), echoGuard: AmbientReplyEchoGuard(),
        diagnostics: diagnostics)
    rig.controller.onUnexpectedStop = { [weak rig] reason in rig?.unexpected.append(reason) }
    return content
}

@MainActor private final class StationLifecyclePlayer: ReplyAudioPlaying {
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}

func requestMicrophonePermission() async -> Bool { true }

@MainActor enum AmbientStopNotifier {
    static func requestAuthorization() {}
    static func post(_ reason: String) {}
    static func reconnected(_ notice: AmbientListeningReconnect.Notice) {}
}

struct OverheardSettingsView: View {
    let connections: HostConnectionStore
    var body: some View { EmptyView() }
}

struct OwnerVoiceUnrecognizedView: View {
    var body: some View { EmptyView() }
}

struct MediaModeStatusView: View {
    let status: MediaModeStatus
    var body: some View { EmptyView() }
}

struct PrivacySwitchView: View {
    let connections: HostConnectionStore
    let hostID: HostEndpoint.Identifier
    let listening: Bool
    var body: some View { EmptyView() }
}

struct AmbientMovedAwayView: View {
    let handoff: AmbientHandoff
    let listenHere: () -> Void
    var body: some View { EmptyView() }
}

struct StationMenuListeningPublisher: ViewModifier {
    let controller: AmbientListeningController
    let binding: AmbientAudioBinding
    func body(content: Content) -> some View { content }
}
