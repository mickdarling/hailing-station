import SwiftUI

@main
struct HailApp: App {
    #if HAIL_CARPLAY
    // CarPlay simulator spike only (#72); see CarPlayVoiceScene.swift.
    @UIApplicationDelegateAdaptor(CarPlayAppDelegate.self) private var carPlayDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
