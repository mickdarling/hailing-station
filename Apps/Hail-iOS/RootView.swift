import HailCore
import HailProtocol
import SwiftUI

/// Thin root: current target, talk control, transcript, last reply. Each area fills in with its issue.
struct RootView: View {
    private static let savedHostsKey = "hailing-station.host-endpoints.v1"
    @State private var connections = HostConnectionStore()
    @State private var audioSession = ManagedAudioSession(backend: AVAudioSessionBackend())
    @State private var selectedHostID: HostEndpoint.Identifier?
    @State private var selectedTargetID: String?
    @State private var didRestoreHosts = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await connections.sceneBecameActive() }
        }
        .task { await restoreHostsOnce() }
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
        Menu {
            if availableDestinations.isEmpty {
                Text("No ready targets")
            }
            ForEach(availableDestinations) { option in
                Button {
                    Task { await select(option) }
                } label: {
                    if destination?.id == option.id {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Label("Target", systemImage: "scope")
        }
        .buttonStyle(.bordered)
    }

    private var availableDestinations: [Destination] {
        connections.hosts.flatMap { host in
            guard host.state == .ready else { return [Destination]() }
            return host.targets.filter(\.alive).map {
                Destination(hostID: host.id, hostName: host.endpoint.name, target: $0)
            }
        }
    }

    private var destination: Destination? {
        guard let selectedHostID, let selectedTargetID else { return nil }
        return availableDestinations.first { $0.hostID == selectedHostID && $0.target.id == selectedTargetID }
    }

    @MainActor
    private func select(_ option: Destination) async {
        do {
            try await connections.selectTarget(host: option.hostID, targetID: option.target.id)
            selectedHostID = option.hostID
            selectedTargetID = option.target.id
        } catch {
            selectedHostID = nil
            selectedTargetID = nil
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
    }
}

private struct Destination: Identifiable, Equatable {
    let hostID: HostEndpoint.Identifier
    let hostName: String
    let target: TargetInfo

    var id: String { "\(hostID)|\(target.id)" }
    var label: String { "\(hostName) · \(target.name)" }
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
