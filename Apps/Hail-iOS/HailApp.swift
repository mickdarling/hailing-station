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
        .commands { shellCommands }
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
        .commands { shellCommands }
        #endif
    }

    @CommandsBuilder private var shellCommands: some Commands {
        if StationRedesignLaunch.flags.isOn(.shell), StationRedesignLaunch.idiom != .phone {
            SidebarCommands()
        }
    }

    private var stationWindow: some View {
        stationContent.modifier(AppearanceSettingsPresentation())
    }

    @ViewBuilder
    private var stationContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-appearance-preview") {
            // An inert, synthetic settings scene for UI tests and screenshots. No station/audio resources exist.
            if ProcessInfo.processInfo.arguments.contains("-appearance-entry-preview") {
                AppearanceEntryPreview()
            } else {
                NavigationStack { AppearanceSettingsView() }
            }
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

#if DEBUG
/// Replaces an outer layout branch under the real window-owned settings presenter; no station resources exist.
private struct AppearanceEntryPreview: View {
    @Environment(ConversationAppearancePreferences.self) private var appearance
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if appearance.previewAlternateLayout {
                ScrollView { tools }
            } else {
                tools
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance.example-tools")
        .environment(\.dynamicTypeSize,
                     ProcessInfo.processInfo.arguments.contains("-appearance-dense-example") ? .xSmall : typeSize)
    }

    private var tools: some View {
        AppearanceSettingsEntry {
            ViewThatFits(in: .horizontal) {
                HStack { ForEach(0..<6) { _ in Text("Example tool").frame(width: 120) } }
                VStack { ForEach(0..<6) { _ in Text("Example tool").frame(height: 30) } }
            }
        }
        .padding()
    }
}
#endif
