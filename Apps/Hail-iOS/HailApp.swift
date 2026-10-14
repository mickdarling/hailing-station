import SwiftUI
#if os(macOS)
import HailCoaching
import HailCore
#endif

@main
struct HailApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(DesktopStationAppDelegate.self) private var applicationDelegate
    private var stationAudio: DesktopStationAudio { applicationDelegate.audio }
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Hailing Station", id: "station") {
            RootView(playback: stationAudio.playback, echoGuard: stationAudio.echoGuard)
                .environment(stationAudio.coaching).environment(stationAudio.exclusion)
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        #else
        WindowGroup { RootView() }
        #endif
    }
}
