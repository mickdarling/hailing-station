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
        .accessibilityValue(destinationAccessibilityValue)
        .accessibilityHint("Opens the Mac and target browser.")
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

    var destinationAccessibilityValue: String {
        guard let destination else { return "None selected" }
        let role = destination.target.kind == "tmux"
            ? "Terminal"
            : "\(destination.target.kind.capitalized) target"
        return "Mac \(destination.endpoint.name). \(role) \(destination.target.name)."
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
            destinationDetails
        }
        .destinationLabelStyle()
    }

    var compactDestinationLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                destinationDetails
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .destinationLabelStyle()
    }

    @ViewBuilder
    var destinationDetails: some View {
        if let destination {
            Text("Mac · \(destination.endpoint.name)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Text(destination.target.kind == "tmux"
                ? "Terminal · \(destination.target.name)"
                : "\(destination.target.kind.capitalized) target · \(destination.target.name)")
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        } else {
            Text("Mac and target")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Choose a destination")
                .font(.headline)
                .lineLimit(2)
        }
    }
}

private extension View {
    func destinationLabelStyle() -> some View {
        frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}
