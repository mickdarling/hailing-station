import HailCore
import SwiftUI

/// Manual Mac setup and connection status for the station.
struct ConnectivityLabView: View {
    @Bindable var store: HostConnectionStore
    let endpointsChanged: @MainActor ([HostEndpoint]) -> Void
    var showsDevicesPage = false
    @Environment(\.stationPalette) private var palette
    @State private var addingMac = false
    @State private var editingID: HostEndpoint.Identifier?
    @State private var name = ""
    @State private var url = ConnectivityLabView.defaultURL
    @State private var validation = ""
    private static let defaultURL = "ws://127.0.0.1:8765"

    var body: some View {
        #if os(macOS)
        if showsDevicesPage {
            devicesPage
        } else {
            setupList
        }
        #else
        setupList
        #endif
    }

    private var setupList: some View {
        List {
            Section("How it works") { instructions }
            Section("Add or edit a Mac") { editor }
            Section("Configured Macs") {
                if store.hosts.isEmpty {
                    Text("Add a Mac address to begin.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts) { host in
                    ConnectivityHostRow(host: host, store: store, edit: { beginEditing(host.endpoint) })
                }
                .onDelete { offsets in remove(offsets.map { store.hosts[$0].id }) }
            }
        }
        .navigationTitle("Mac Setup")
        .stationToolBackNavigation()
    }

    @ViewBuilder private var instructions: some View {
        Label("1. Add this Mac's Hailing Station WebSocket address.", systemImage: "1.circle")
        Label("2. Connect and wait for Ready.", systemImage: "2.circle")
        Label("3. Return to the station and choose a target.", systemImage: "3.circle")
    }

    @ViewBuilder private var editor: some View {
        TextField("Name", text: $name)
        TextField("WebSocket URL", text: $url)
            .stationURLInput()
            .autocorrectionDisabled()
        if !validation.isEmpty {
            Text(validation).foregroundStyle(showsDevicesPage ? palette[.stateWarning] : .red)
        }
        Button(editingID == nil ? "Add Mac" : "Save Mac") { Task { await save() } }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func remove(_ ids: [HostEndpoint.Identifier]) {
        Task {
            for id in ids { await store.remove(id) }
            endpointsChanged(store.hosts.map(\.endpoint))
        }
    }

    private func save() async {
        guard let parsedURL = URL(string: url) else {
            validation = "Enter a ws:// or wss:// URL."
            return
        }
        do {
            if store.hosts.contains(where: {
                $0.endpoint.url == parsedURL && $0.id != editingID
            }) {
                validation = "That Mac address is already configured. Edit the existing entry instead."
                return
            }
            let id = editingID ?? UUID().uuidString.lowercased()
            await store.upsert(try HostEndpoint(id: id, name: name, url: parsedURL))
            endpointsChanged(store.hosts.map(\.endpoint))
            validation = ""
            editingID = nil
            name = ""
            addingMac = false
        } catch {
            validation = "Enter a name and a ws:// or wss:// URL with a host."
        }
    }

    private func beginEditing(_ endpoint: HostEndpoint) {
        addingMac = false
        editingID = endpoint.id
        name = endpoint.name
        url = endpoint.url.absoluteString
        validation = ""
    }
}

#if os(macOS)
private extension ConnectivityLabView {
    var devicesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    heading("Configured Macs")
                    Spacer()
                    Button("Add a Mac", systemImage: "plus") { beginAdding() }
                        .disabled(addingMac)
                        .accessibilityIdentifier("station.devices.mac-setup")
                }
                if addingMac { panel { deviceEditor } }
                if store.hosts.isEmpty {
                    panel { Text("Add a Mac address to begin.").foregroundStyle(palette[.textSecondary]) }
                }
                ForEach(store.hosts) { host in
                    panel {
                        if editingID == host.id {
                            deviceEditor
                        } else {
                            ConnectivityHostRow(host: host, store: store, palette: palette,
                                                edit: { beginEditing(host.endpoint) }, remove: { remove([host.id]) })
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("station.devices.host.\(host.id)")
                }
                heading("How it works").padding(.top, 6)
                panel { instructions.font(.callout).foregroundStyle(palette[.textSecondary]) }
            }
            .padding(16)
        }
        .background(palette[.surface])
        .foregroundStyle(palette[.textPrimary], palette[.textSecondary])
        .tint(palette[.brand])
        .navigationTitle("Devices")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("station.devices.setup-page")
    }

    var deviceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(addingMac ? "Add a Mac" : "Edit Mac")
            editor
            Button("Cancel") {
                editingID = nil
                addingMac = false
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    func beginAdding() {
        editingID = nil
        name = ""
        url = Self.defaultURL
        validation = ""
        addingMac = true
    }

    func heading(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
    }

    func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { StationRowSurface() }
            .clipShape(.rect(cornerRadius: 10))
    }
}
#endif
