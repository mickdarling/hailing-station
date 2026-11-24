import CoreFoundation
import Foundation
import HailCore
import Observation
import SwiftUI

/// The app owns one preference store, shared with its Settings window and sheets. No service or audio owner.
@MainActor @Observable
final class ConversationAppearancePreferences {
    private let defaults: UserDefaults
    private(set) var state: ConversationTextSize
    var previewAlternateLayout = false // Inert Debug fixture only; never persisted.

    init(defaults: UserDefaults = .standard, platform: ConversationTextSize.Platform = .currentAppearancePlatform) {
        self.defaults = defaults
        let number = defaults.object(forKey: ConversationTextSize.storageKey) as? NSNumber
        let stored = number.flatMap { value -> Int? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return Int(exactly: value.doubleValue)
        }
        state = ConversationTextSize(platform: platform, stored: stored)
    }

    func apply(_ intent: ConversationTextSize.Intent) {
        state = state.applying(intent)
        defaults.set(state.size, forKey: ConversationTextSize.storageKey)
    }
}

extension ConversationTextSize.Platform {
    static var currentAppearancePlatform: Self {
        #if os(macOS)
        .mac
        #else
        .touch
        #endif
    }
}

/// The "Aa" control (#1115): Smaller, Larger and Reset for the conversation's own text size, with the current value
/// and a live preview. It renders a `ConversationTextSize` and emits its intents; the owner at the app root stores
/// the choice. It never changes the system's text settings or the size of app controls, and binds no keys.
///
/// VoiceOver users can adjust it in place: swiping up or down on the button is Larger or Smaller.
struct ConversationTextSizeControl: View {
    let state: ConversationTextSize
    let onIntent: (ConversationTextSize.Intent) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
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
                .stationCompactPresentation(sheet: typeSize.isAccessibilitySize)
        }
    }
}

/// The panel: the value, the three actions, then a preview at the resulting size. The actions come before the
/// uncapped preview, and the panel scrolls, so at accessibility sizes no action is ever pushed out of reach (Codex
/// review of #1166).
private struct ConversationTextSizePanel: View {
    @Environment(\.stationPalette) private var palette
    let state: ConversationTextSize
    let onIntent: (ConversationTextSize.Intent) -> Void
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Conversation text").font(.headline)
                        Spacer()
                        Text(state.label).foregroundStyle(palette[.textSecondary])
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Conversation text").font(.headline)
                        Text(state.label).foregroundStyle(palette[.textSecondary])
                    }
                }
                .accessibilityElement(children: .combine)
                ConversationTextSizeActions(state: state, onIntent: onIntent)
                Text("What you say and Haili's replies appear at this size.")
                    .font(.system(size: state.pointSize(bodyScale: bodyScale)))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("station.text-size.preview")
            }
            .padding()
        }
        .background(palette[.elevatedSurface])
        .foregroundStyle(palette[.textPrimary], palette[.textSecondary])
        .frame(minWidth: 280)
    }
}

/// Shared native actions for the Aa popover and Settings > Appearance.
struct ConversationTextSizeActions: View {
    @Environment(\.activeStationPalette) private var palette
    let state: ConversationTextSize
    let onIntent: (ConversationTextSize.Intent) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let row = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            row {
                Button("Smaller", systemImage: "textformat.size.smaller") { onIntent(.smaller) }
                    .disabled(!state.canShrink)
                    .accessibilityIdentifier("appearance.text-size.smaller")
                Button("Larger", systemImage: "textformat.size.larger") { onIntent(.larger) }
                    .disabled(!state.canGrow)
                    .accessibilityIdentifier("appearance.text-size.larger")
            }
            .buttonStyle(.bordered)
            if let note = state.boundNote {
                let label = Text(note).font(.caption)
                if let palette { label.foregroundStyle(palette[.textSecondary]) } else {
                    label.foregroundStyle(.secondary)
                }
            }
            Button("Reset to app default") { onIntent(.reset) }
                .disabled(state.isDefault)
                .accessibilityIdentifier("appearance.text-size.reset")
        }
    }
}

private extension View {
    /// On iPhone, a popover so the conversation stays in view while the size changes; at accessibility sizes, a
    /// sheet, which has the height the larger text needs.
    @ViewBuilder
    func stationCompactPresentation(sheet: Bool) -> some View {
        #if os(iOS)
        presentationCompactAdaptation(sheet ? .sheet : .popover)
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
