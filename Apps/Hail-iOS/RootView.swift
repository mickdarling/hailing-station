import HailCore
import HailProtocol
import SwiftUI

/// Shared station state for the adaptive iPhone and iPad interface.
struct RootView: View {
    private static let savedHostsKey = "hailing-station.host-endpoints.v1"
    let selectionStore: any DestinationSelectionStoring
    @State var connections = HostConnectionStore()
    @State var audioSession: ManagedAudioSession
    @State var audioRoutes: AudioRouteModel
    @State var playback: ReplyPlaybackController
    /// Shared by reply playback and ambient capture (#227): the player raises it before audio can be heard.
    @State var echoGuard: AmbientReplyEchoGuard
    /// Keeps the station running in the background while connected without ambient listening (#352).
    @State var keepalive = BackgroundKeepalive(renderer: SilentAudioKeepalive())
    /// The "Diagnostics logging" log (#234): off by default; records and sends nothing until turned on.
    @State var diagnostics = DeviceDiagnostics()
    @State var selectedHostID: HostEndpoint.Identifier?
    @State var selectedTargetID: String?
    @State var rememberedSelection: DestinationSelection?
    @State var didRestoreHosts = false
    @State var didRestoreSelection = false
    @State var isRestoringSelection = false
    @State var selectionAuthorizedForReadyConnection = false
    @State var authorizedConnectionGeneration: UUID?
    @State var selectionRevision: UInt = 0
    @State var showingDestinations = false
    @State var scenePhaseRevision: UInt = 0
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    @MainActor
    init(selectionStore: any DestinationSelectionStoring = UserDefaultsDestinationSelectionStore()) {
        let session = ManagedAudioSession(backend: AVAudioSessionBackend())
        self.selectionStore = selectionStore
        _audioSession = State(initialValue: session)
        _audioRoutes = State(initialValue: AudioRouteModel(controller: session))
        let echoGuard = AmbientReplyEchoGuard()
        let playback = ReplyPlaybackController(player: echoGuard.guarding(PCM16AudioPlayer()))
        echoGuard.follow(playback)
        _echoGuard = State(initialValue: echoGuard)
        _playback = State(initialValue: playback)
    }

    var body: some View {
        NavigationStack {
            content
        }
        .onChange(of: scenePhase) { _, phase in
            scenePhaseRevision &+= 1
            selectionRevision &+= 1
            let revision = scenePhaseRevision
            // While ambient listening streams, the destination stays authorized in the background so the stream
            // and its replies continue (#282); returning to the foreground re-checks it as before.
            if phase != .active, !connections.ambientStreaming {
                selectionAuthorizedForReadyConnection = false
                authorizedConnectionGeneration = nil
            }
            // The keepalive stops before anything in the foreground configures the session (#352).
            if phase == .active { keepalive.sceneActive = true }
            Task {
                if phase == .active {
                    await connections.sceneBecameActive()
                    guard scenePhaseRevision == revision,
                          scenePhase == .active else { return }
                    await reconcileRememberedSelection()
                    return
                }
                if !connections.ambientStreaming {
                    // Ambient listening keeps the audio session active in the background (#282): deactivating it
                    // would stop capture and let iOS suspend the app. The controller releases it when it stops.
                    await audioRoutes.sceneBecameInactive()
                }
                // Only after that release, which would otherwise stop the keepalive it started. Only in the
                // background: Control Center, a permission alert or the app switcher leave the scene merely
                // inactive, and a keepalive started there could deactivate capture ambient has just activated (#354).
                if scenePhaseRevision == revision, phase == .background { keepalive.sceneActive = false }
            }
        }
        .onChange(of: connections.hosts) { _, _ in
            guard scenePhase == .active else { return }
            Task { await reconcileRememberedSelection() }
        }
        .task {
            // Directly from the store, not a view update, so replies also play in the background (#282).
            let playback = playback
            connections.onReplyFrame = { playback.ingest($0) }
            let keepalive = keepalive
            // Releases a session left active for an audible reply once that reply ends (#354).
            keepalive.follow(playback)
            audioRoutes.onDeactivate = { keepalive.sessionWasReleased() }
            keepalive.follow(connections)
        }
        .task {
            await audioRoutes.observe()
        }
        .task {
            connections.diagnostics = diagnostics
            diagnostics.observeSystem()
            diagnostics.watch(playback)
        }
        .task {
            await restoreHostsOnce()
            await restoreSelectionOnce()
        }
    }

    @MainActor
    private func restoreHostsOnce() async {
        guard !didRestoreHosts else { return }
        didRestoreHosts = true
        guard let data = UserDefaults.standard.data(forKey: Self.savedHostsKey),
              let endpoints = try? JSONDecoder().decode([HostEndpoint].self, from: data) else { return }
        let remembered = await selectionStore.load()
        var normalized: [HostEndpoint] = []
        for endpoint in endpoints {
            if let duplicate = normalized.firstIndex(where: { $0.url == endpoint.url }) {
                if endpoint.id == remembered?.hostID { normalized[duplicate] = endpoint }
            } else {
                normalized.append(endpoint)
            }
        }
        for endpoint in normalized {
            await connections.upsert(endpoint)
            await connections.connect(endpoint.id)
        }
        if normalized.count != endpoints.count { persist(normalized) }
    }

    @MainActor
    func persist(_ endpoints: [HostEndpoint]) {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedHostsKey)
        guard let rememberedSelection,
              !endpoints.contains(where: rememberedSelection.matches(endpoint:)) else { return }
        Task { await forgetSelection() }
    }
}

struct LabsView: View {
    let audioSession: any AudioSessionDiagnosticsProviding

    var body: some View {
        List {
            NavigationLink("Live transcription") {
                if #available(iOS 26.0, *) {
                    TranscriptionLabView(audioSession: audioSession)
                }
            }
            NavigationLink("Routing spike") { RoutingSpikeView() }
        }
        .navigationTitle("Labs")
    }
}

#Preview {
    RootView()
}
