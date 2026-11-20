import HailCore
import SwiftUI

@main
struct HailApp: App {
    @State private var appearance: ConversationAppearancePreferences
    #if os(macOS)
    /// Shared by the station window and the menu-bar extra (#266).
    @State private var menuStatus = StationMenuStatus()
    #endif

    init() {
        _appearance = State(initialValue: Self.makeAppearancePreferences())
    }

    var body: some Scene {
        #if os(macOS)
        // One station per Mac: a second window would open a second connection and a second reply player (#266).
        Window("Hailing Station", id: MacMenuBar.windowID) {
            stationWindow
                .environment(menuStatus)
                .environment(appearance)
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        MenuBarExtra("Hailing Station", systemImage: MacMenuBar.symbol(for: menuStatus)) {
            MacMenuBarContent(status: menuStatus)
        }
        Settings {
            AppearanceSettingsView()
                .environment(appearance)
                .frame(minWidth: 560, minHeight: 520)
        }
        #else
        WindowGroup {
            stationWindow.environment(appearance)
        }
        #endif
    }

    @ViewBuilder
    private var stationWindow: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-appearance-preview") {
            // An inert, synthetic settings scene for UI tests and screenshots. No station/audio resources exist.
            NavigationStack { AppearanceSettingsView() }
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }

    private static func makeAppearancePreferences() -> ConversationAppearancePreferences {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-appearance-preview") {
            let suite = "hailing-station.appearance-ui-preview"
            guard let defaults = UserDefaults(suiteName: suite) else {
                preconditionFailure("Could not open isolated appearance preview preferences")
            }
            if ProcessInfo.processInfo.arguments.contains("-reset-appearance-preview") {
                defaults.removePersistentDomain(forName: suite)
            }
            return ConversationAppearancePreferences(defaults: defaults)
        }
        #endif
        return ConversationAppearancePreferences()
    }
}
