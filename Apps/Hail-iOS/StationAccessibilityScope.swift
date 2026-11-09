import SwiftUI

/// Keeps the hidden station out of the accessibility tree (#1115).
///
/// The shell keeps the station page mounted while another section shows, so a capture never ends, and collapses it.
/// `.accessibilityHidden` around the page's `NavigationStack` doesn't reach the content inside it, and SwiftUI hosts
/// some of that content apart from the stack's root: a `.safeAreaInset`, a toolbar item, a pushed view. So the shell
/// sets `stationAccessibilityHidden` on the page instead, which the environment carries to every part of it, and each
/// part the station hosts on its own applies `stationAccessibilityScope()`: the root, the build footer and, as each
/// is adopted, the station's toolbar items. #1183's UI test sweeps the whole tree for anything that forgets it.
extension View {
    /// Hidden from accessibility while the station is.
    func stationAccessibilityScope() -> some View {
        modifier(StationAccessibilityScope())
    }
}

extension EnvironmentValues {
    /// True while the shell keeps the station mounted but shows another section.
    var stationAccessibilityHidden: Bool {
        get { self[StationAccessibilityHiddenKey.self] }
        set { self[StationAccessibilityHiddenKey.self] = newValue }
    }
}

private struct StationAccessibilityHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

private struct StationAccessibilityScope: ViewModifier {
    @Environment(\.stationAccessibilityHidden) private var hidden

    func body(content: Content) -> some View {
        content.accessibilityHidden(hidden)
    }
}
