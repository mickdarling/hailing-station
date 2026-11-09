import HailCore
import SwiftUI

/// The "Aa" control (#1115): Smaller, Larger and Reset for the conversation's own text size, with the current value
/// and a live preview. It renders a `ConversationTextSize` and emits its intents; the owner at the app root stores
/// the choice. It never changes the system's text settings or the size of app controls, and binds no keys.
///
/// VoiceOver users can adjust it in place: swiping up or down on the button is Larger or Smaller.
struct ConversationTextSizeControl: View {
    let state: ConversationTextSize
    let onIntent: (ConversationTextSize.Intent) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Text("Aa")
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Conversation text size")
        .accessibilityValue(state.accessibilityValue)
        .accessibilityHint("Shows smaller, larger and reset.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onIntent(.larger)
            case .decrement: onIntent(.smaller)
            default: break
            }
        }
        .accessibilityIdentifier("station.text-size")
        .popover(isPresented: $isPresented) {
            ConversationTextSizePanel(state: state, onIntent: onIntent)
                .stationCompactPopover()
        }
    }
}

/// The popover's content: the value, a preview at the resulting size, and the three actions.
private struct ConversationTextSizePanel: View {
    let state: ConversationTextSize
    let onIntent: (ConversationTextSize.Intent) -> Void
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversation text").font(.headline)
                Spacer()
                Text(state.label).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Text("What you say and Haili's replies appear at this size.")
                .font(.system(size: state.pointSize(bodyScale: bodyScale)))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("station.text-size.preview")
            HStack(spacing: 8) {
                Button("Smaller", systemImage: "textformat.size.smaller") { onIntent(.smaller) }
                    .disabled(!state.canShrink)
                Button("Larger", systemImage: "textformat.size.larger") { onIntent(.larger) }
                    .disabled(!state.canGrow)
            }
            .buttonStyle(.bordered)
            if let note = state.boundNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Button("Reset to app default") { onIntent(.reset) }
                .disabled(state.isDefault)
        }
        .padding()
        .frame(minWidth: 280)
    }
}

private extension View {
    /// A popover on iPhone too, not a full sheet, so the conversation stays in view while the size changes.
    @ViewBuilder
    func stationCompactPopover() -> some View {
        #if os(iOS)
        presentationCompactAdaptation(.popover)
        #else
        self
        #endif
    }
}

#Preview("Text size · synthetic") {
    @Previewable @State var state = ConversationTextSize(platform: .touch, stored: nil)
    VStack(spacing: 16) {
        ConversationTextSizeControl(state: state) { state = state.applying($0) }
        ConversationTextSizePanel(state: state) { state = state.applying($0) }
    }
}
