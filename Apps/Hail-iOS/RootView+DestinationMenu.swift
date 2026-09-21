import SwiftUI

extension RootView {
    @ViewBuilder
    var destinationMenu: some View {
        Button {
            showingDestinations = true
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                accessibleDestinationLabel
            } else {
                compactDestinationLabel
            }
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("station.destination")
        .accessibilityLabel("Destination")
        .accessibilityValue(destination?.label ?? "None selected")
        .accessibilityHint("Opens the host and target browser.")
        .popover(isPresented: $showingDestinations) {
            DestinationBrowser(
                hosts: connections.hosts,
                selected: destination,
                usesPopoverLayout: horizontalSizeClass == .regular,
                onSelect: { option in Task { await select(option) } }
            )
            .presentationCompactAdaptation(.sheet)
        }
    }

    var accessibleDestinationLabel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "scope")
                    .font(.title3)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(destination?.label ?? "Choose a Mac and target")
                .font(.headline)
                .lineLimit(3)
        }
        .destinationLabelStyle()
    }

    var compactDestinationLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Destination")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(destination?.label ?? "Choose a Mac and target")
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .destinationLabelStyle()
    }
}

private extension View {
    func destinationLabelStyle() -> some View {
        frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}
