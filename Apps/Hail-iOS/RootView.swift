import HailCore
import HailProtocol
import SwiftUI

// Keep the native type distinct from the existing destination-selection test shell.
#if !SWIFT_PACKAGE
typealias RootView = StationRootView
#endif

/// Shared station state for the adaptive iPhone and iPad interface.
struct StationRootView: View {
    private static let savedHostsKey = "hailing-station.host-endpoints.v1"
    let selectionStore: any DestinationSelectionStoring
    @StateObject var station: StationSceneState<StationResources>
    var connections: HostConnectionStore { station.value.connections }
    var audioSession: ManagedAudioSession { station.value.audioSession }
    var audioRoutes: AudioRouteModel { station.value.audioRoutes }
    var playback: ReplyPlaybackController { station.value.playback }
    var echoGuard: AmbientReplyEchoGuard { station.value.echoGuard }
    var keepalive: BackgroundKeepalive { station.value.keepalive }
    var diagnostics: DeviceDiagnostics { station.value.diagnostics }
    var announcementBanners: AnnouncementBanners {
        get { station.value.announcementBanners }
        nonmutating set { station.value.announcementBanners = newValue }
    }
    @State var announcer: Announcer?
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
    init(
        selectionStore: any DestinationSelectionStoring = UserDefaultsDestinationSelectionStore(),
        makeResources: @escaping () -> StationResources = { StationResources() }
    ) {
        self.selectionStore = selectionStore
        _station = StateObject(wrappedValue: StationSceneState(makeResources))
    }

    var body: some View {
        NavigationStack {
            content
        }
        .modifier(StationMenuStatusPublisher(connections: connections, destination: destination?.label))
        .modifier(ReplySegmentNotices(connections: connections, banners: $station.value.announcementBanners))
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
            let selectedHost = $selectedHostID
            connections.wireReplySegments(playback: playback, echoGuard: echoGuard) { [weak connections] endpoint in
                guard let connections else { return (false, true) }
                let privacy = connections.duckMode[endpoint]?.isOn() == true
                    || connections.privacyLocal[endpoint]?.request?.on == true
                return (connections.ambientStreaming && selectedHost.wrappedValue == endpoint, privacy)
            }
            // Directly from the store, not a view update, so replies also play in the background (#282).
            let playback = playback
            connections.onReplyFrame = { playback.ingest($0) }
            // One announcement per refused request, whatever its code (#608, #636); the chat shows it too.
            connections.onRequestRefusal = { StationPlatform.announce($0) }
            startAnnouncer()
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
            await playback.follow(audioSession) // interruption holds end on the session's actual resume (#469)
        }
        .task {
            connections.diagnostics = diagnostics
            echoGuard.diagnostics = diagnostics
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
        let saved = UserDefaults.standard.data(forKey: Self.savedHostsKey)
            .flatMap { try? JSONDecoder().decode([HostEndpoint].self, from: $0) }
        guard let endpoints = await withLocalHost(saved) else { return }
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
