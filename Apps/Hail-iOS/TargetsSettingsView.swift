import HailCore
import SwiftUI

enum TargetsSettingsIntent {
    case chooseDestinationInStation
}

struct TargetsSettingsConfirmation {
    let selection: DestinationSelection
    let generation: UUID
}

/// A conservative reading of the root's confirmation and saved identity. It cannot select a destination.
struct TargetsSettingsState {
    let hosts: [HostConnectionSnapshot]
    let destination: DestinationControlState
    let remembered: DestinationSelection?

    var savedHostName: String {
        hosts.first { remembered?.matches(endpoint: $0.endpoint) == true }?.endpoint.name
            ?? "Previously configured Mac"
    }
    var savedHostMatches: Bool { hosts.contains { remembered?.matches(endpoint: $0.endpoint) == true } }

    static func resolve(
        hosts: [HostConnectionSnapshot], availability: StationAvailability,
        confirmed: TargetsSettingsConfirmation?, remembered: DestinationSelection?
    ) -> Self {
        let current = confirmed.flatMap { confirmation -> DestinationLabel? in
            guard remembered == confirmation.selection else { return nil }
            return label(confirmation.selection, hosts: hosts, generation: confirmation.generation)
        }
        let saved = remembered.flatMap { label($0, hosts: hosts, generation: nil) }
        return Self(hosts: hosts, destination: DestinationControlState.resolve(
            availability: availability, confirmed: current, remembered: saved), remembered: remembered)
    }

    static func connectionText(_ state: HostConnectionState) -> String {
        switch state {
        case .ready: "Connected"
        case .connecting, .negotiating: "Connecting"
        case .reconnecting: "Reconnecting"
        case .failed: "Connection failed"
        case .disconnected: "Offline"
        }
    }

    private static func label(
        _ selection: DestinationSelection, hosts: [HostConnectionSnapshot], generation: UUID?
    ) -> DestinationLabel? {
        guard let host = hosts.first(where: { selection.matches(endpoint: $0.endpoint) }) else { return nil }
        if let generation {
            guard host.state == .ready, host.receivedTargetList,
                  host.connectionGeneration == generation else { return nil }
        }
        guard let target = host.targets.first(where: {
            $0.id == selection.targetID && $0.name == selection.targetName && (generation == nil || $0.alive)
        }) else { return nil }
        return DestinationLabel(hostName: host.endpoint.name, targetName: target.name,
                                targetKind: target.kind, targetID: target.id)
    }
}

struct TargetsSettingsView<Setup: View>: View {
    let state: TargetsSettingsState
    let send: (TargetsSettingsIntent) -> Void
    @ViewBuilder let setup: () -> Setup

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.destination.primaryText)
                    if state.destination.talkReady, let detail = state.destination.secondaryText {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.targets.destination")
                Button("Choose destination in Station") { send(.chooseDestinationInStation) }
                    .accessibilityIdentifier("settings.targets.choose")
            } header: {
                Text("Destination · this device")
            } footer: {
                Text("Opens Station. Use its destination control to choose a Mac and target.")
            }
            if let saved = state.remembered, !state.destination.talkReady {
                Section {
                    LabeledContent("Mac", value: state.savedHostName)
                    LabeledContent("Target", value: saved.targetName)
                } header: {
                    Text("Saved · not confirmed")
                } footer: {
                    Text(state.savedHostMatches ? "The saved destination is not current."
                         : "The saved Mac address no longer matches a configured Mac.")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.targets.saved")
            }
            Section("Configured Macs · this device") {
                if state.hosts.isEmpty {
                    Text("No Macs configured.").accessibilityIdentifier("settings.targets.no-macs")
                }
                ForEach(state.hosts) { host in hostRow(host) }
                NavigationLink { setup() } label: { Label("Mac Setup", systemImage: "network") }
                    .accessibilityIdentifier("settings.targets.mac-setup")
            }
            Section("Target policy") {
                Text("Target policies and route aliases are not editable here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Targets")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.targets.page")
    }

    private func hostRow(_ host: HostConnectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(host.endpoint.name).font(.headline)
            Text(TargetsSettingsState.connectionText(host.state)).font(.subheadline)
            if host.state == .ready, host.receivedTargetList {
                if host.targets.isEmpty { Text("No allowed targets reported.").foregroundStyle(.secondary) }
                ForEach(host.targets, id: \.id) { target in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(target.name) · \(target.kind)")
                        Text(target.alive ? "Reported running" : "Reported stopped")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.targets.offered.\(host.id).\(target.id)")
                }
            } else {
                Text(host.state == .ready ? "Waiting for target list." : "Targets are not confirmed on this connection.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.targets.mac.\(host.id)")
    }
}

/// The supplied store stays at the root. Rendering only reads its existing snapshots.
struct TargetsSettingsOverview<Setup: View>: View {
    let store: HostConnectionStore
    let availability: StationAvailability
    let confirmed: TargetsSettingsConfirmation?
    let remembered: DestinationSelection?
    let send: (StationNavigationIntent) -> Void
    @ViewBuilder let setup: () -> Setup

    var body: some View {
        TargetsSettingsView(state: TargetsSettingsState.resolve(
            hosts: store.hosts, availability: availability, confirmed: confirmed, remembered: remembered
        ), send: apply, setup: setup)
    }

    func apply(_ intent: TargetsSettingsIntent) {
        switch intent {
        case .chooseDestinationInStation: send(.select(.station))
        }
    }
}
