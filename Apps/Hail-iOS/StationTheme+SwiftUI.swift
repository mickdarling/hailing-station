import HailCore
import SwiftUI

private enum StationThemeKey: EnvironmentKey {
    static let defaultValue: StationTheme? = nil
}

extension EnvironmentValues {
    /// Set only on the flag-on shell. Views shared with the original station keep their native styling outside it.
    var stationTheme: StationTheme? {
        get { self[StationThemeKey.self] }
        set { self[StationThemeKey.self] = newValue }
    }

    /// Redesign-only components can also render in an isolated SwiftUI preview.
    var stationPalette: StationPalette {
        StationPalette(theme: stationTheme ?? .astra, scheme: colorScheme)
    }
}

#if !SWIFT_PACKAGE
#Preview("Navigation shell · synthetic") {
    @Previewable @State var state = StationNavigationState()
    StationNavigationShell(state: state, idiom: StationRedesignLaunch.idiom,
        send: { state.apply($0) },
        detail: { Text($0.title).frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle($0.title) },
        inspector: { Text("Inspector") },
        dock: { _ in Button("Full conversation") { state.apply(.toggleFullConversation) }.padding() }
    )
}
#endif

struct StationPalette {
    let theme: StationTheme
    let scheme: ColorScheme

    subscript(role: StationTheme.Role) -> Color {
        let pair = theme[role]
        let rgb = scheme == .dark ? pair.dark : pair.light
        return Color(.sRGB, red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}

/// Resolves in the row's own environment, including when SwiftUI hosts the list background separately.
struct StationRowSurface: View {
    @Environment(\.stationPalette) private var palette

    var body: some View { palette[.elevatedSurface] }
}

/// Shared station surfaces retain their original colours when the shell has supplied no theme.
struct StationCanvasBackground: ViewModifier {
    let original: Color
    @Environment(\.activeStationPalette) private var palette

    func body(content: Content) -> some View {
        content.background(palette?[.surface] ?? original)
    }
}

extension EnvironmentValues {
    var activeStationPalette: StationPalette? {
        stationTheme.map { StationPalette(theme: $0, scheme: colorScheme) }
    }
}

struct StationTalkDisc: ViewModifier {
    let recording: Bool
    @Environment(\.activeStationPalette) private var palette

    func body(content: Content) -> some View {
        let fill = palette?[recording ? .stateLive : .accentTalk] ?? (recording ? Color.red : Color.accentColor)
        content.foregroundStyle(palette?[.brandOnBrand] ?? .white)
            .background(fill, in: Circle())
            .shadow(color: fill.opacity(0.25), radius: 12, y: 6)
    }
}

struct StationTalkButtonStyle: ButtonStyle {
    let recording: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.stationPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        let colors: (fill: StationTheme.Role, ink: StationTheme.Role) = isEnabled
            ? (recording ? .stateLive : .accentTalk, .brandOnBrand)
            : (.textSecondary, .elevatedSurface)
        configuration.label
            .padding(.horizontal, 8)
            .foregroundStyle(palette[colors.ink])
            .background(palette[colors.fill], in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
