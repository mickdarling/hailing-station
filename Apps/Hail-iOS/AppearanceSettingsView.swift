import HailCore
import SwiftUI

/// Native local Appearance settings, based on the #1239 frames. The conversation below is authored preview text.
struct AppearanceSettingsView: View {
    @Environment(ConversationAppearancePreferences.self) private var appearance
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading
                textSize
                preview
                Label("Saved on this device", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(.background)
        .navigationTitle("Appearance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("appearance.settings")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This device", systemImage: "display")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            #if os(macOS)
            Text("Appearance").font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
            #endif
            Text("Make room for your conversation.")
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Choose a comfortable reading size. Your system text size and app controls stay unchanged.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var textSize: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Conversation text").font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 16)
                        value
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Conversation text").font(.headline).accessibilityAddTraits(.isHeader)
                        value
                    }
                }
                ConversationTextSizeActions(state: appearance.state, onIntent: appearance.apply)
                Text("Preview preference. Live conversation text sizing is not available yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var value: some View {
        Text(appearance.state.label)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Text size")
            .accessibilityValue(appearance.state.accessibilityValue)
            .accessibilityIdentifier("appearance.text-size.value")
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Conversation preview").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text("Example").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 20) {
                previewMessage("You", text: "Let's make this easier to read.")
                previewMessage(
                    "Haili", text: "Choose the size that feels comfortable. The preview updates as you adjust it."
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("appearance.conversation-preview")
        }
    }

    private func previewMessage(_ speaker: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(speaker)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: appearance.state.pointSize(bodyScale: bodyScale)))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A sheet keeps the station mounted. Opening Settings never constructs another station or audio owner.
struct AppearanceSettingsEntry<Tools: View>: View {
    /// The root's OS setting, before StationLayout applies its deliberately denser conversation layout.
    let typeSize: DynamicTypeSize
    private let tools: Tools
    @Environment(ConversationAppearancePreferences.self) private var appearance
    @State private var isPresented = false

    init(typeSize: DynamicTypeSize, @ViewBuilder tools: () -> Tools) {
        self.typeSize = typeSize
        self.tools = tools()
    }

    var body: some View {
        // Own presentation above the adaptive tool row: swapping its horizontal/vertical layout cannot dismiss it.
        VStack(spacing: 10) {
            tools
            Button {
                isPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("station.settings")
        }
        .sheet(isPresented: $isPresented) {
            AppearanceSettingsSheet(typeSize: typeSize) { isPresented = false }
                .environment(appearance)
        }
    }
}

/// Explicit OS text scale prevents StationLayout's local density adjustment from entering Settings.
struct AppearanceSettingsSheet: View {
    let typeSize: DynamicTypeSize
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            AppearanceSettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDismiss)
                    }
                }
        }
        .environment(\.dynamicTypeSize, typeSize)
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 420)
        #endif
    }
}
