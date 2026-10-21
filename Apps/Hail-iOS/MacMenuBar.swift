#if os(macOS)
import AppKit
import HailCore
import SwiftUI

/// The Mac menu-bar extra (#266): status, a quick listening toggle, the station window and Quit. Listening goes
/// through the window's own ambient card, so it is available only while the window shows one.
struct MacMenuBarContent: View {
    let status: StationMenuStatus
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status.summary)
        Divider()
        Toggle("Ambient Listening", isOn: Binding(get: { status.listening.isOn }, set: { status.setListening($0) }))
            .disabled(!status.canToggleListening)
        Button("Open Hailing Station") {
            openWindow(id: MacMenuBar.windowID)
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Divider()
        Button("Quit Hailing Station") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum MacMenuBar {
    static let windowID = "station"

    @MainActor
    static func symbol(for status: StationMenuStatus) -> String {
        switch status.listening {
        case .listening: return "ear.fill"
        case .starting: return "ear"
        case .paused: return "pause.circle"
        case .off, .elsewhere: break
        }
        return status.windowOpen && status.readyHostCount > 0
            ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    }
}
#endif
