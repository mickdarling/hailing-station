import HailCore
import HailProtocol
import SwiftUI

/// Host-scoped target selection. iPhone presents this as a sheet; iPad keeps the spatial popover.
struct DestinationBrowser: View {
    let hosts: [HostConnectionSnapshot]
    let selected: Destination?
    let usesPopoverLayout: Bool
    let onSelect: @MainActor (Destination) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if hosts.isEmpty {
                    ContentUnavailableView(
                        "No Macs configured",
                        systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                        description: Text("Add and connect a Mac from Connections.")
                    )
                }
                ForEach(hosts) { host in
                    Section {
                        targetRows(for: host)
                    } header: {
                        hostHeader(host)
                    }
                }
            }
            .navigationTitle("Choose a target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: usesPopoverLayout ? 420 : nil)
        .frame(minHeight: 360, idealHeight: 520)
    }

    @ViewBuilder
    private func targetRows(for host: HostConnectionSnapshot) -> some View {
        if host.state != .ready {
            Label(host.state.selectionLabel, systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
        } else if !host.receivedTargetList {
            Label("Loading targets", systemImage: "ellipsis")
                .foregroundStyle(.secondary)
        } else if host.targets.isEmpty {
            Label("No allowed targets", systemImage: "nosign")
                .foregroundStyle(.secondary)
        } else {
            ForEach(host.targets, id: \.id) { target in
                targetButton(target, on: host)
            }
        }
    }

    private func targetButton(_ target: TargetInfo, on host: HostConnectionSnapshot) -> some View {
        let option = Destination(endpoint: host.endpoint, target: target)
        let isSelected = selected?.id == option.id
        return Button {
            onSelect(option)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: target.alive ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(target.alive ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name)
                    Text(target.kind).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .disabled(!target.alive)
        .accessibilityIdentifier(option.label)
        .accessibilityLabel(
            "\(target.name), \(target.kind) target, host \(host.endpoint.name), \(host.endpoint.url.absoluteString)"
        )
        .accessibilityValue(target.accessibilityValue(isSelected: isSelected))
        .accessibilityHint(target.alive ? "Selects this target" : "This target is unavailable")
    }

    private func hostHeader(_ host: HostConnectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.endpoint.name).font(.headline)
            Text(host.endpoint.url.absoluteString)
                .font(.caption.monospaced())
                .textCase(nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Host \(host.endpoint.name), \(host.endpoint.url.absoluteString)")
        .accessibilityValue(host.state.selectionLabel)
    }
}

private extension HostConnectionState {
    var selectionLabel: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .negotiating: "Negotiating"
        case .ready: "Ready"
        case .reconnecting: "Reconnecting"
        case .failed: "Connection failed"
        }
    }
}

private extension TargetInfo {
    func accessibilityValue(isSelected: Bool) -> String {
        if !alive { return "Unavailable" }
        return isSelected ? "Live, selected" : "Live"
    }
}
