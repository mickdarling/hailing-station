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
