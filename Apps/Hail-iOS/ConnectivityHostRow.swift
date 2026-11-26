import HailCore
import HailProtocol
import SwiftUI

/// Both Mac setup presentations observe the same snapshot and health reading.
struct ConnectivityHostRow: View {
    let host: HostConnectionSnapshot
    let store: HostConnectionStore
    var palette: StationPalette?
    let edit: () -> Void
    var remove: (() -> Void)?

    private var warning: Color { palette?[.stateWarning] ?? .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(host.endpoint.name).font(.headline)
                    Text(host.endpoint.url.absoluteString)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                connectionBadge
            }
            HStack {
                Button("Connect") { Task { await store.connect(host.id) } }
                Button("Disconnect") { Task { await store.disconnect(host.id) } }
                Button("Edit", action: edit)
                if let remove { Button("Remove", role: .destructive, action: remove) }
            }
            .buttonStyle(.bordered)
            diagnostics
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var connectionBadge: some View {
        let label = Text(host.state.label).font(.caption.weight(.medium))
        if let palette {
            label.foregroundStyle(palette[host.state == .ready ? .brand : .stateOffline])
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(palette[.surface], in: .rect(cornerRadius: 7))
        } else {
            label
        }
    }

    @ViewBuilder
    private var diagnostics: some View {
        if let version = host.negotiatedVersion {
            Text("protocol v\(version) · \(host.capabilities.joined(separator: ", "))")
                .font(.caption.monospaced())
        }
        if let ping = host.lastPingMilliseconds {
            Text("last ping \(ping.formatted(.number.precision(.fractionLength(1)))) ms")
                .font(.caption.monospaced())
        }
        healthSummary
        if host.receivedTargetList, host.targets.isEmpty {
            Text("No allowed targets returned.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(host.targets, id: \.id) { target in
            if palette != nil {
                Text("\(target.name) · \(target.kind) · \(target.alive ? "Running" : "Stopped")").font(.caption)
            } else {
                Text("\(target.alive ? "●" : "○") \(target.name) · \(target.kind)").font(.caption)
            }
        }
    }

    /// The host's doctor summary (#614), read-only, when it answers `health`; refreshable while connected.
    @ViewBuilder
    private var healthSummary: some View {
        if let reading = store.health[host.id] {
            let health = reading.report
            VStack(alignment: .leading, spacing: 4) {
                if reading.isStale(for: host) {
                    Text("From an earlier connection").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Label(health.headline, systemImage: health.healthy ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(health.healthy ? (palette?[.brand] ?? .green) : warning)
                ForEach(Array(health.lines.enumerated()), id: \.offset) { _, line in
                    Label(line.title, systemImage: line.ok ? "checkmark" : "xmark")
                        .font(.caption)
                        .foregroundStyle(line.ok ? (palette?[.textSecondary] ?? .secondary) : warning)
                }
                Text(health.buildLine).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connectivity.host-health")
        }
        if host.state == .ready, host.capabilities.contains(HostHealth.capability) {
            Button("Check host health") { store.requestHealth(host.id) }
                .font(.caption)
                .buttonStyle(.borderless)
        }
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
