import HailCore
import SwiftUI

extension RootView {
    var screenDestination: DestinationControlState {
        let confirmed = destination.map {
            DestinationLabel(hostName: $0.endpoint.name, targetName: $0.target.name,
                             targetKind: $0.target.kind, targetID: $0.target.id)
        }
        let saved = rememberedSelection.flatMap { TargetsSettingsState.label($0, hosts: connections.hosts,
                                                                             generation: nil) }
        return .resolve(availability: stationAvailability, confirmed: confirmed, remembered: saved)
    }
}

struct StationScreenHeader<Browser: View>: View {
    let destination: DestinationControlState
    let availability: StationAvailability
    @Binding var showingDestinations: Bool
    @ViewBuilder var browser: () -> Browser
    @Environment(\.stationPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            DestinationControlView(state: destination, style: .toolbar, identifier: "station.destination",
                                   isBrowserPresented: $showingDestinations, browser: browser)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            Label(availability.connectionLabel, systemImage: availability.badge.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette[availability == .ready ? .brand : .textSecondary])
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(palette[.surface], in: .rect(cornerRadius: 7))
                .accessibilityIdentifier("station.connection")
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(palette[.elevatedSurface])
    }
}
