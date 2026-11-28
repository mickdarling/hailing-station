import HailCore
import SwiftUI
#if os(macOS) && DEBUG
import AppKit
import Combine
#endif

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
                #if DEBUG
                .background {
                    // Only Debug-ShellUITests uses this bundle identifier.
                    if Bundle.main.bundleIdentifier == "com.mickdarling.Hail-macOS-shell-tests" {
                        ShellTestWindowPlacement()
                    }
                }
                #endif
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
                #if STATION_UI_FIXTURES && targetEnvironment(simulator)
                .modifier(StationFixtureAppearance(isFixture: Self.displaySeedName != nil
                                                   || StationScreenSeed.requested != nil))
                #endif
        }
        .commands { shellCommands }
        #endif
    }

    #if STATION_UI_FIXTURES
    private static let displaySeedName = StationDisplaySeedLaunch.name(
        in: ProcessInfo.processInfo.arguments, bundleID: Bundle.main.bundleIdentifier,
        shellEnabled: StationRedesignLaunch.flags.isOn(.shell))
    #endif

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
            #if STATION_UI_FIXTURES
            if let name = Self.displaySeedName {
                if let state = StationTranscriptSeed(rawValue: name) {
                    StationDisplayFixture(state: state)
                } else {
                    Text("Unknown station display fixture")
                }
            } else if let seed = StationScreenSeed.requested {
                RootView(makeResources: seed.resources)
            } else {
                RootView()
            }
            #else
            RootView()
            #endif
        }
        #else
        RootView()
        #endif
    }

    private static func makeAppearancePreferences() -> ConversationAppearancePreferences {
        #if STATION_UI_FIXTURES
        if Self.displaySeedName != nil {
            let suite = "hailing-station.transcript-ui"
            guard let defaults = UserDefaults(suiteName: suite) else {
                preconditionFailure("Could not open isolated transcript preferences")
            }
            defaults.removePersistentDomain(forName: suite)
            return ConversationAppearancePreferences(defaults: defaults)
        }
        #endif
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

#if os(macOS) && DEBUG
private struct ShellTestWindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacementView { PlacementView() }
    func updateNSView(_ view: PlacementView, context: Context) {}

    final class PlacementView: NSView {
        private var firstKey: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            firstKey = nil
            guard let window, let value = ProcessInfo.processInfo.environment["SHELL_UI_TEST_WINDOW_FRAME"] else {
                return
            }
            let frame = NSRectFromString(value)
            // Set the actual station window's frame after AppKit has restored or positioned it.
            if window.isKeyWindow {
                window.setFrame(frame, display: true)
            } else {
                firstKey = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window)
                    .first()
                    .sink { [weak window] _ in window?.setFrame(frame, display: true) }
            }
        }
    }
}
#endif

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
