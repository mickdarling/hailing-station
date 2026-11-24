import HailCore
import SwiftUI

struct StationSidebarBrand: View {
    @Environment(\.stationPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.headline)
                .foregroundStyle(palette[.brandOnBrand])
                .frame(width: 34, height: 36)
                .background(palette[.accentTalk], in: .rect(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Hailing Station").font(.headline)
                Text("Your voice. Your workspace.")
                    .font(.caption).foregroundStyle(palette[.textSecondary])
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

struct StationSidebarSessions: View {
    let session: DestinationLabel?
    @Environment(\.stationPalette) private var palette

    var body: some View {
        Section("Sessions") {
            if let session {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.targetName)
                        Text("Selected · \(session.hostName)").font(.caption)
                    }
                } icon: { Image(systemName: "circle.fill").font(.caption2) }
                .selectionDisabled()
                .listRowBackground(palette[.elevatedSurface])
            } else {
                Text("No session selected").font(.callout)
                    .foregroundStyle(palette[.textSecondary])
                    .selectionDisabled().listRowBackground(palette[.sidebar])
            }
        }
    }
}

extension Destination {
    var stationLabel: DestinationLabel {
        DestinationLabel(hostName: endpoint.name, targetName: target.name, targetKind: target.kind, targetID: target.id)
    }
}
