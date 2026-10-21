import HailCore
import SwiftUI

@main
struct HailApp: App {
    #if os(macOS)
    /// Shared by the station window and the menu-bar extra (#266).
    @State private var menuStatus = StationMenuStatus()
    #endif

    var body: some Scene {
        #if os(macOS)
        // One station per Mac: a second window would open a second connection and a second reply player (#266).
        Window("Hailing Station", id: MacMenuBar.windowID) {
            RootView()
                .environment(menuStatus)
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        MenuBarExtra("Hailing Station", systemImage: MacMenuBar.symbol(for: menuStatus)) {
            MacMenuBarContent(status: menuStatus)
        }
        #else
        WindowGroup {
            RootView()
        }
        #endif
    }
}
