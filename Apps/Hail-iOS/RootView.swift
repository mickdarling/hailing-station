import HailCore
import HailProtocol
import SwiftUI

/// Thin root: current target, talk control, transcript, last reply. Each area fills in with its issue.
struct RootView: View {
    private static let savedHostsKey = "hailing-station.host-endpoints.v1"
    let selectionStore: any DestinationSelectionStoring
    @State var connections = HostConnectionStore()
    @State private var audioSession = ManagedAudioSession(backend: AVAudioSessionBackend())
    @State private var playback = ReplyPlaybackController(player: PCM16AudioPlayer())
    @State var selectedHostID: HostEndpoint.Identifier?
    @State var selectedTargetID: String?
    @State var rememberedSelection: DestinationSelection?
    @State var didRestoreHosts = false
    @State var didRestoreSelection = false
    @State var isRestoringSelection = false
    @State var selectionAuthorizedForReadyConnection = false
    @State var selectionRevision: UInt = 0
    @State private var showingDestinations = false
    @Environment(\.scenePhase) private var scenePhase

    init(selectionStore: any DestinationSelectionStoring = UserDefaultsDestinationSelectionStore()) {
        self.selectionStore = selectionStore
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
            await restoreHostsOnce()
            await restoreSelectionOnce()
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hailing Station").font(.title.bold())
                    Text(destination?.label ?? "Choose a destination")
                        .foregroundStyle(destination == nil ? .secondary : .primary)
                }
                Spacer()
                destinationMenu
            }

            if let destination {
                if #available(iOS 26.0, *) {
                    TranscriptionLabView(
                        audioSession: audioSession,
                        destinationLabel: destination.label,
                        onFinalized: { text in
                            try await connections.sendFinalText(
                                text, host: destination.hostID, targetID: destination.target.id
                            )
                        },
                        onEscape: {
                            try await connections.sendEscape(
                                host: destination.hostID, targetID: destination.target.id
                            )
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "Requires iOS 26",
                        systemImage: "waveform.badge.exclamationmark",
                        description: Text("SpeechAnalyzer is unavailable on this device.")
                    )
                }
            } else {
                ContentUnavailableView(
                    "No target selected",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Connect to your Mac, then choose an allowed target.")
                )
            }

            if let reply = playback.latest {
                ReplyPlaybackView(reply: reply, playback: playback)
            }

            HStack {
                NavigationLink("Connections") {
                    ConnectivityLabView(store: connections, endpointsChanged: persist)
                }
                NavigationLink("Audio") { AudioDiagnosticsView(controller: audioSession) }
                NavigationLink("Labs") { LabsView(audioSession: audioSession) }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    @ViewBuilder
    private var destinationMenu: some View {
        Button {
            showingDestinations = true
        } label: {
            Label("Target", systemImage: "scope")
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showingDestinations) {
            DestinationBrowser(
                hosts: connections.hosts,
                selected: destination,
                onSelect: { option in Task { await select(option) } }
            )
            .presentationCompactAdaptation(.sheet)
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
    private func persist(_ endpoints: [HostEndpoint]) {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedHostsKey)
        guard let rememberedSelection,
              !endpoints.contains(where: rememberedSelection.matches(endpoint:)) else { return }
        Task { await forgetSelection() }
    }
}

private struct LabsView: View {
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
