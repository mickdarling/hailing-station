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
    @State var playback = ReplyPlaybackController(player: PCM16AudioPlayer())
    @State var selectedHostID: HostEndpoint.Identifier?
    @State var selectedTargetID: String?
    @State var rememberedSelection: DestinationSelection?
    @State var didRestoreHosts = false
    @State var didRestoreSelection = false
    @State var isRestoringSelection = false
    @State var selectionAuthorizedForReadyConnection = false
    @State var selectionRevision: UInt = 0
    @State var showingDestinations = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    @MainActor
    init(selectionStore: any DestinationSelectionStoring = UserDefaultsDestinationSelectionStore()) {
        let session = ManagedAudioSession(backend: AVAudioSessionBackend())
        self.selectionStore = selectionStore
        _audioSession = State(initialValue: session)
        _audioRoutes = State(initialValue: AudioRouteModel(controller: session))
    }

    var body: some View {
        NavigationStack {
            content
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await connections.sceneBecameActive() }
        }
        .onChange(of: connections.replyFrames) { _, frames in
            for frame in frames { playback.ingest(frame) }
        }
        .onChange(of: connections.hosts) { _, _ in
            Task { await reconcileRememberedSelection() }
        }
        .task {
            await audioRoutes.observe()
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
        for endpoint in endpoints {
            await connections.upsert(endpoint)
            await connections.connect(endpoint.id)
        }
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
