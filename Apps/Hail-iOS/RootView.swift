import HailCore
import HailProtocol
import SwiftUI

/// Thin root: current target, talk control, transcript, last reply. Each area fills in with its issue.
struct RootView: View {
    @State private var connections = HostConnectionStore()
    @State private var audioSession = ManagedAudioSession(backend: AVAudioSessionBackend())
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await connections.sceneBecameActive() }
        }
    }

    private var content: some View {
        VStack(spacing: 24) {
            Text("Hailing Station")
                .font(.largeTitle.weight(.semibold))
            Text("no target selected")
                .foregroundStyle(.secondary)
            Text("protocol v\(ProtocolVersion.current)")
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
            NavigationLink("Connectivity Lab (#99)") { ConnectivityLabView(store: connections) }
            NavigationLink("Audio session (#4)") { AudioDiagnosticsView(controller: audioSession) }
            NavigationLink("Live transcription (#6)") {
                if #available(iOS 26.0, *) {
                    TranscriptionLabView(audioSession: audioSession)
                } else {
                    ContentUnavailableView(
                        "Requires iOS 26",
                        systemImage: "waveform.badge.exclamationmark",
                        description: Text("SpeechAnalyzer is unavailable on this device.")
                    )
                }
            }
            NavigationLink("Routing spike (#22)") { RoutingSpikeView() }
        }
        .padding()
    }
}

/// Temporary diagnostics surface for proving multiple independent Mac connections before terminal styling lands.
private struct ConnectivityLabView: View {
    @Bindable var store: HostConnectionStore
    @State private var editingID: HostEndpoint.Identifier?
    @State private var name = ""
    @State private var url = "ws://127.0.0.1:8765"
    @State private var validation = ""

    var body: some View {
        List {
            Section("Add or edit a Mac") {
                TextField("Name", text: $name)
                TextField("WebSocket URL", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if !validation.isEmpty { Text(validation).foregroundStyle(.red) }
                Button(editingID == nil ? "Add host" : "Save host") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Hosts") {
                if store.hosts.isEmpty {
                    Text("Add a Mac URL to begin the connection probe.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts) { host in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(host.endpoint.name).font(.headline)
                                Text(host.endpoint.url.absoluteString)
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(host.state.label).font(.caption.weight(.medium))
                        }
                        HStack {
                            Button("Connect") { Task { await store.connect(host.id) } }
                            Button("Disconnect") { Task { await store.disconnect(host.id) } }
                            Button("Edit") { beginEditing(host.endpoint) }
                        }
                        .buttonStyle(.bordered)
                        diagnostics(host)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.hosts[$0].id }
                    Task { for id in ids { await store.remove(id) } }
                }
            }
        }
        .navigationTitle("Connectivity Lab")
    }

    @ViewBuilder
    private func diagnostics(_ host: HostConnectionSnapshot) -> some View {
        if let version = host.negotiatedVersion {
            Text("protocol v\(version) · \(host.capabilities.joined(separator: ", "))")
                .font(.caption.monospaced())
        }
        if let ping = host.lastPingMilliseconds {
            Text("last ping \(ping.formatted(.number.precision(.fractionLength(1)))) ms")
                .font(.caption.monospaced())
        }
        if host.receivedTargetList, host.targets.isEmpty {
            Text("No allowed targets returned.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(host.targets, id: \.id) { target in
            Text("\(target.alive ? "●" : "○") \(target.name) · \(target.kind)")
                .font(.caption)
        }
    }

    private func save() async {
        guard let parsedURL = URL(string: url) else {
            validation = "Enter a ws:// or wss:// URL."
            return
        }
        do {
            let endpoint = try HostEndpoint(id: editingID ?? UUID().uuidString.lowercased(), name: name, url: parsedURL)
            await store.upsert(endpoint)
            validation = ""
            editingID = nil
            name = ""
        } catch {
            validation = "Enter a name and a ws:// or wss:// URL with a host."
        }
    }

    private func beginEditing(_ endpoint: HostEndpoint) {
        editingID = endpoint.id
        name = endpoint.name
        url = endpoint.url.absoluteString
        validation = ""
    }
}

private extension HostConnectionState {
    var label: String {
        switch self {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .negotiating: "negotiating"
        case .ready: "ready"
        case .reconnecting(let attempt, let delay):
            "retry \(attempt) in \(delay.formatted(.number.precision(.fractionLength(1))))s"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

#Preview {
    RootView()
}
