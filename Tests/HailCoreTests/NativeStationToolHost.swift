import AppKit
import Observation
import SwiftUI
import Testing

/// Hosts the shipped lifecycle wrapper / diagnostics view; controls use a programmatic NavigationStack path.
@MainActor
@Observable private final class StationToolPath {
    var values: [Int] = []
    var appearances = 0
}

@MainActor
private struct StationToolNavigationScene<Content: View>: View {
    let path: StationToolPath
    let isTool: Bool
    let content: Content

    var body: some View {
        NavigationStack(path: Binding(get: { path.values }, set: { path.values = $0 })) {
            Group {
                // macOS retains navigation roots. Mirror iOS visibility so the shipped card actually disappears.
                if isTool || !path.values.isEmpty { Text("Station") }
                else { content.onAppear { path.appearances += 1 } }
            }
            .navigationDestination(for: Int.self) { _ in
                if isTool { content.onAppear { path.appearances += 1 } } else { Text("Station tool") }
            }
        }
    }
}

@MainActor
final class NativeStationToolHost {
    private let path = StationToolPath()
    private let window: NSWindow

    init(_ content: some View, isTool: Bool = false) {
        _ = NSApplication.shared
        let path = path
        if isTool { path.values = [1] }
        let root = StationToolNavigationScene(path: path, isTool: isTool, content: content)
        let hosting = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
    }

    func appeared() async throws {
        try await waitUntil { await MainActor.run { self.path.appearances > 0 } }
    }

    func push() { path.values = [1] }
    func pop() { path.values = [] }

    func back() async throws {
        path.values = []
        try await waitUntil { await MainActor.run { self.path.appearances > 1 } }
    }

    func finish() { window.close() }
}

// Back-button cosmetics are outside the tool lifecycle test; NavigationStack itself is real SwiftUI.
extension View {
    func stationToolBackNavigation() -> some View { self }
}
