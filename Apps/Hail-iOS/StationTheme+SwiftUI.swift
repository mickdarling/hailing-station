import HailCore
import SwiftUI

extension EnvironmentValues {
    /// Set only on the flag-on shell. Views shared with the original station keep their native styling outside it.
    @Entry var stationTheme: StationTheme?

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
