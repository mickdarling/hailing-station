import HailCore
import SwiftUI

/// "Check Mac connection" on the station's empty state (#385). It used to be only a link to Mac Setup, which read as
/// doing nothing. Now it reconnects the Mac at once, shows that it is checking, then the result. Mac Setup stays
/// one tap away beside it.
struct StationConnectionCheckView: View {
    let connections: HostConnectionStore
    /// The Macs the station is waiting on: the remembered one, or every configured Mac.
    let hostIDs: [HostEndpoint.Identifier]
    let endpointsChanged: @MainActor ([HostEndpoint]) -> Void
    @State private var result: StationConnectionCheck?
    @State private var check: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(spacing: 10) { buttons }
            }
            if let result {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if result == .checking {
                        ProgressView().accessibilityHidden(true)
                    } else {
                        Image(systemName: result.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(result.isProblem ? .orange : .green)
                            .accessibilityHidden(true)
                    }
                    Text(result.message)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("station.connection-check-result")
                }
                .font(.subheadline)
            }
        }
        .onDisappear {
            // A cancelled check goes back to idle: the station keeps this state while Mac Setup is pushed (#385).
            check?.cancel()
            if result == .checking { result = nil }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            runCheck()
        } label: {
            Label("Check Mac connection", systemImage: "network")
        }
        .buttonStyle(.borderedProminent)
        .disabled(result == .checking)
        .accessibilityIdentifier("station.check-connection")
        NavigationLink {
            ConnectivityLabView(store: connections, endpointsChanged: endpointsChanged)
        } label: {
            Label("Mac Setup", systemImage: "gearshape")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("station.setup-mac")
    }

    private func runCheck() {
        check?.cancel()
        result = .checking
        let ids = hostIDs
        let stale = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            connections.snapshots[id].map { (id, $0.connectionGeneration) }
        })
        check = Task { @MainActor in
            // Only the Macs checked: retrying ones skip their backoff, a ready one is pinged, a disconnected one stays.
            await connections.checkConnection(ids)
            let outcome = await StationConnectionCheck.wait(
                for: { ids.compactMap { connections.snapshots[$0] } }, staleGenerations: stale
            )
            if !Task.isCancelled { result = outcome }
        }
    }
}
