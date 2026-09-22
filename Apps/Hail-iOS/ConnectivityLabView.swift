import HailCore
import SwiftUI

/// Manual Mac setup and connection status for the station.
struct ConnectivityLabView: View {
    @Bindable var store: HostConnectionStore
    let endpointsChanged: @MainActor ([HostEndpoint]) -> Void
    @State private var editingID: HostEndpoint.Identifier?
    @State private var name = ""
    @State private var url = "ws://127.0.0.1:8765"
    @State private var validation = ""

    var body: some View {
        List {
            Section("How it works") {
                Label("1. Add this Mac's Hailing Station WebSocket address.", systemImage: "1.circle")
                Label("2. Connect and wait for Ready.", systemImage: "2.circle")
                Label("3. Return to the station and choose a target.", systemImage: "3.circle")
            }

            Section("Add or edit a Mac") {
                TextField("Name", text: $name)
                TextField("WebSocket URL", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if !validation.isEmpty { Text(validation).foregroundStyle(.red) }
                Button(editingID == nil ? "Add Mac" : "Save Mac") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Configured Macs") {
                if store.hosts.isEmpty {
                    Text("Add a Mac address to begin.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts) { host in
                    hostRow(host)
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.hosts[$0].id }
                    Task {
                        for id in ids { await store.remove(id) }
                        endpointsChanged(store.hosts.map(\.endpoint))
                    }
                }
            }
        }
        .navigationTitle("Mac Setup")
    }

    private func hostRow(_ host: HostConnectionSnapshot) -> some View {
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
            Text("\(target.alive ? "●" : "○") \(target.name) · \(target.kind)").font(.caption)
        }
    }

    private func save() async {
        guard let parsedURL = URL(string: url) else {
            validation = "Enter a ws:// or wss:// URL."
            return
        }
        do {
            let id = editingID ?? UUID().uuidString.lowercased()
            await store.upsert(try HostEndpoint(id: id, name: name, url: parsedURL))
            endpointsChanged(store.hosts.map(\.endpoint))
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
