import HailCore
import SwiftUI

extension RootView {
    var content: some View {
        resetStationStateForUITestingIfRequested()
        return ScrollView {
            VStack(spacing: 18) {
                StationHeader(connection: connectionPresentation) {
                    destinationMenu
                }
                adaptiveContent
            }
            .frame(maxWidth: 1_120)
            .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    var adaptiveContent: some View {
        let layout = horizontalSizeClass == .regular
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(spacing: 18))
        return layout {
            VStack(spacing: 18) {
                conversationSurface
                if let reply = playback.latest {
                    ReplyPlaybackView(reply: reply, playback: playback)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            VStack(spacing: 18) {
                AudioRouteSummaryView(model: audioRoutes)
                stationTools
            }
            .frame(maxWidth: horizontalSizeClass == .regular ? 360 : .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    var conversationSurface: some View {
        if let destination {
            TranscriptionLabView(
                audioSession: audioRoutes,
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
            VStack(spacing: 16) {
                Image(systemName: hasReadyHost ? "scope" : "macbook.and.iphone")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(hasReadyHost ? "Choose a destination" : "Connect Haley to a Mac")
                    .font(.title3.bold())
                Text(hasReadyHost
                    ? "Your Mac is connected. Choose the allowed terminal session or target Haley should use."
                    : "Add this Mac, connect it, then choose the terminal session Haley should use.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if hasReadyHost {
                    Button {
                        showingDestinations = true
                    } label: {
                        Label("Choose a destination", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("station.choose-destination")
                } else {
                    NavigationLink {
                        ConnectivityLabView(store: connections, endpointsChanged: persist)
                    } label: {
                        Label("Set up a Mac", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("station.setup-mac")
                }
            }
            .padding(24)
            .stationCard(minHeight: horizontalSizeClass == .regular ? 420 : 260)
        }
    }

    var stationTools: some View {
        GroupBox {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { toolLinks }
                VStack(spacing: 10) { toolLinks }
            }
            .buttonStyle(.bordered)
        } label: {
            Label("Station tools", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .accessibilityIdentifier("station.tools")
    }

    @ViewBuilder
    var toolLinks: some View {
        NavigationLink {
            ConnectivityLabView(store: connections, endpointsChanged: persist)
        } label: {
            Label("Mac Setup", systemImage: "network")
                .frame(maxWidth: .infinity)
        }
        NavigationLink {
            AudioDiagnosticsView(model: audioRoutes)
        } label: {
            Label("Audio", systemImage: "waveform")
                .frame(maxWidth: .infinity)
        }
        NavigationLink {
            LabsView(audioSession: audioRoutes)
        } label: {
            Label("Labs", systemImage: "wrench.and.screwdriver")
                .frame(maxWidth: .infinity)
        }
    }

    var connectionPresentation: StationConnectionPresentation {
        if destination != nil {
            return StationConnectionPresentation(
                label: "Ready",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        }
        if connections.hosts.contains(where: { $0.state == .ready }) {
            return StationConnectionPresentation(
                label: "Choose a target",
                systemImage: "scope",
                color: .blue
            )
        }
        if connections.hosts.contains(where: {
            switch $0.state {
            case .connecting, .negotiating, .reconnecting: true
            default: false
            }
        }) {
            return StationConnectionPresentation(
                label: "Connecting",
                systemImage: "arrow.trianglehead.2.clockwise",
                color: .orange
            )
        }
        if connections.hosts.contains(where: {
            if case .failed = $0.state { return true }
            return false
        }) {
            return StationConnectionPresentation(
                label: "Needs attention",
                systemImage: "exclamationmark.triangle.fill",
                color: .red
            )
        }
        return StationConnectionPresentation(
            label: connections.hosts.isEmpty ? "No Mac configured" : "Offline",
            systemImage: "circle.dashed",
            color: .secondary
        )
    }

    var hasReadyHost: Bool {
        connections.hosts.contains(where: { $0.state == .ready })
    }

    /// Keeps the empty-state UI test deterministic without changing normal launch persistence.
    @MainActor
    private func resetStationStateForUITestingIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-reset-station-state"),
              !StationUITestReset.didRun else { return }
        StationUITestReset.didRun = true
        UserDefaults.standard.removeObject(forKey: "hailing-station.host-endpoints.v1")
        UserDefaults.standard.removeObject(forKey: "hailing-station.destination-selection.v1")
    }
}

@MainActor
private enum StationUITestReset {
    static var didRun = false
}

private extension View {
    func stationCard(minHeight: CGFloat = 320) -> some View {
        frame(maxWidth: .infinity, minHeight: minHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
