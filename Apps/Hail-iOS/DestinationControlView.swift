import HailCore
import SwiftUI

/// The destination control (#1115). It renders a `DestinationControlState`, and its one action opens the owner's
/// destination browser. It never selects, clears or changes a target, recipient or route: choosing a destination
/// still runs from that browser through the station's own selection flow.
///
/// Only a confirmed destination uses the confirmed glyph and the primary style. Any other state leads with what is
/// happening ("Confirming…", "Unavailable: offline"), and a saved destination follows in secondary style, marked
/// "not confirmed", so the last value never looks current.
struct DestinationControlView<Browser: View>: View {
    enum Style {
        /// The Mac toolbar and iPad: one line, with the browser in a popover.
        case toolbar
        /// iPhone: two lines at full width, with the browser in a sheet.
        case compact
    }

    @Environment(\.stationPalette) private var palette
    let state: DestinationControlState
    var style: Style = .compact
    var identifier = "station.destination-control"
    /// Owned by the station; the control only asks for the browser to be shown.
    @Binding var isBrowserPresented: Bool
    @ViewBuilder let browser: () -> Browser
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button {
            isBrowserPresented = true
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Destination")
        .accessibilityValue(state.accessibilityValue)
        .accessibilityHint("Opens the Mac and target browser.")
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $isBrowserPresented) {
            browser()
                .presentationCompactAdaptation(.sheet)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .toolbar where state.talkReady:
            HStack(spacing: 10) {
                glyph.padding(8).background(palette[.surface], in: .rect(cornerRadius: 8))
                if case .confirmed(let label) = state {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label.targetName).font(.headline)
                        Text("\(label.hostName) · \(label.role)")
                            .font(.caption).foregroundStyle(palette[.textSecondary])
                    }
                }
                Image(systemName: "chevron.down").font(.caption)
            }
            .contentShape(Rectangle())
        case .toolbar:
            Label { Text(state.singleLineText).lineLimit(1) } icon: { glyph }
                .foregroundStyle(state.talkReady ? palette[.textPrimary] : unavailableInk)
        case .compact:
            HStack(spacing: 12) {
                glyph.font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.primaryText)
                        .font(.headline)
                        .foregroundStyle(state.talkReady ? palette[.textPrimary] : unavailableInk)
                    if let secondary = state.secondaryText {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(palette[.textSecondary])
                    }
                }
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette[.textSecondary])
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette[.elevatedSurface], in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var unavailableInk: Color {
        if case .unavailable(.offline, _) = state { return palette[.stateOffline] }
        return palette[.textSecondary]
    }

    /// The scope glyph belongs to a confirmed destination only.
    private var glyph: some View {
        let symbol = switch state {
        case .confirmed: "scope"
        case .confirming: "circle.dashed"
        case .unavailable: "circle.slash"
        case .none: "plus.circle"
        }
        return Image(systemName: symbol)
            .foregroundStyle(state.talkReady ? palette[.brand] : unavailableInk)
    }
}

#Preview("Destination control · synthetic") {
    @Previewable @State var presented = false
    let label = DestinationLabel(hostName: "Studio", targetName: "build", targetKind: "tmux", targetID: "%1")
    let states: [DestinationControlState] = [
        .confirmed(label), .confirming(saved: label), .unavailable(.offline, saved: label), .none
    ]
    VStack(spacing: 12) {
        ForEach(states.indices, id: \.self) { index in
            DestinationControlView(state: states[index], isBrowserPresented: $presented) { Text("Browser") }
        }
    }
    .padding()
}
