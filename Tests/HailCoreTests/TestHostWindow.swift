#if os(macOS)
import AppKit

@MainActor
final class TestHostWindow: NSPanel {
    /// Visibility tests can deliver an occlusion transition while the real panel stays safely offscreen.
    var fixtureOcclusion: NSWindow.OcclusionState?
    override var occlusionState: NSWindow.OcclusionState { fixtureOcclusion ?? super.occlusionState }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init(size: NSSize) {
        _ = NSApplication.shared
        self.init(contentRect: NSRect(origin: NSPoint(x: -20_000, y: 0), size: size),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        hasShadow = false
        alphaValue = 0
    }

    func mount(_ view: NSView) {
        contentView = view
        // Keep the view mounted in AppKit's window list for SwiftUI lifecycle, accessibility and bitmap capture.
        orderBack(nil)
    }
}
#endif
