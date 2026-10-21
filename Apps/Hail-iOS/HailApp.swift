import SwiftUI

@main
struct HailApp: App {
    var body: some Scene {
        #if os(macOS)
        // One station per Mac: a second window would open a second connection and a second reply player (#266).
        Window("Hailing Station", id: "station") {
            RootView()
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        #else
        WindowGroup {
            RootView()
        }
        #endif
    }
}
