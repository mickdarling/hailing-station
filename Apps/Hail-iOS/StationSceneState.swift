import Combine
import HailCore
import SwiftUI

/// StateObject defers this value's factory until the view identity is installed.
@MainActor
final class StationSceneState<Value>: ObservableObject {
    @Published var value: Value

    init(_ makeValue: () -> Value) { value = makeValue() }
}

/// Each window owns a complete station, including its native route model.
@MainActor
struct StationResources {
    let connections = HostConnectionStore()
    let audioSession: ManagedAudioSession
    let audioRoutes: AudioRouteModel
    let playback: ReplyPlaybackController
    let echoGuard: AmbientReplyEchoGuard
    let keepalive: BackgroundKeepalive
    let diagnostics = DeviceDiagnostics()
    var announcementBanners = AnnouncementBanners()

    init(
        backend: any AudioSessionBackend = StationPlatform.audioSessionBackend(),
        player: any ReplyAudioPlaying = PCM16AudioPlayer(),
        keepaliveRenderer: any BackgroundKeepaliveRendering = StationPlatform.keepaliveRenderer()
    ) {
        let session = ManagedAudioSession(backend: backend)
        audioSession = session
        audioRoutes = AudioRouteModel(controller: session)
        let guarder = AmbientReplyEchoGuard()
        let controller = ReplyPlaybackController(player: guarder.guarding(player))
        guarder.follow(controller)
        echoGuard = guarder
        playback = controller
        keepalive = BackgroundKeepalive(renderer: keepaliveRenderer)
    }
}

struct TranscriptionResources {
    let capture: any AudioCapturing
    let transcriber: any Transcriber
}

#if !SWIFT_PACKAGE
struct LabsView: View {
    let audioSession: any AudioSessionDiagnosticsProviding

    var body: some View {
        List {
            NavigationLink("Live transcription") {
                if #available(iOS 26.0, *) {
                    TranscriptionLabView(audioSession: audioSession)
                }
            }
            #if os(iOS)
            NavigationLink("Routing spike") { RoutingSpikeView() }
            #endif
        }
        .navigationTitle("Labs")
    }
}

#Preview {
    RootView()
}

extension RootView {
    /// Spoken cues the station makes itself, through the reply player (#825 S4b); never lost when unheard (#822).
    func startAnnouncer() {
        guard announcer == nil else { return } // Once: a second would announce every existing problem again.
        let announcer = Announcer(playback: playback, renderer: LocalAnnouncementRenderer()) { announcement, _ in
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            #endif
            announcementBanners.append(announcement.fallbackText)
            StationPlatform.announce(announcement.fallbackText)
        }
        announcer.watchReplyAudio { !StationPlatform.voiceOverRunning } // VoiceOver hears the deferred ones (#86).
        self.announcer = announcer
    }
}

#endif
