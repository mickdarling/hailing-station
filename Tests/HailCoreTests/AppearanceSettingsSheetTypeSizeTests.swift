#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore

/// Measure the shipped sheet's authored preview, never a mirrored font calculation or a station/audio scene.
@Suite("Appearance sheet preserves the root text size", .serialized)
@MainActor
struct AppearanceSettingsSheetTypeSizeTests {
    @Test func stationDensityCannotShrinkTheSettingsPreview() async throws {
        let suite = "AppearanceSettingsSheetTypeSizeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ConversationAppearancePreferences(defaults: defaults, platform: .mac)
        let host = AppearanceSheetSizeHost(preferences: preferences)
        defer { host.finish() }

        let normal = try await host.previewFrame(rootTypeSize: .large, inheritedTypeSize: .large)
        let denseStation = try await host.previewFrame(rootTypeSize: .large, inheritedTypeSize: .xSmall)
        #expect(abs(denseStation.width - normal.width) < 0.5)
        #expect(abs(denseStation.height - normal.height) < 0.5)

        // Sensitivity control: the actual root choice must still affect the rendered preview. Equal frames alone
        // could pass if the measurement or the sheet ignored Dynamic Type altogether.
        let smallerRoot = try await host.previewFrame(rootTypeSize: .xSmall, inheritedTypeSize: .large)
        #expect(smallerRoot.height < normal.height)
    }
}

@MainActor
private final class AppearanceSheetSizeHost {
    private let preferences: ConversationAppearancePreferences
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let window: NSWindow

    init(preferences: ConversationAppearancePreferences) {
        self.preferences = preferences
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1_100),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
    }

    func previewFrame(rootTypeSize: DynamicTypeSize, inheritedTypeSize: DynamicTypeSize) async throws -> NSRect {
        hosting.rootView = AnyView(
            AppearanceSettingsSheet(typeSize: rootTypeSize) {}
                .environment(preferences)
                .environment(\.dynamicTypeSize, inheritedTypeSize)
                .environment(\.accessibilityEnabled, true)
                .transaction { $0.disablesAnimations = true; $0.animation = nil }
        )
        for _ in 0..<8 {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        let frame = try #require(findPreviewFrame(in: hosting), "Authored preview text is missing from native AX.")
        try #require(frame.width > 0 && frame.height > 0, "Native preview text must have a nonempty rendered frame.")
        return frame
    }

    func finish() { window.close() }

    private func findPreviewFrame(in value: Any) -> NSRect? {
        guard let object = value as? NSObject else { return nil }
        func attribute(_ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        // Prefer the text leaf over any ancestor that repeats its label.
        for child in (attribute("accessibilityChildren") as? [Any]) ?? [] {
            if let frame = findPreviewFrame(in: child) { return frame }
        }
        let text = "Let's make this easier to read."
        let matches = (attribute("accessibilityLabel") as? String) == text
            || (attribute("accessibilityValue") as? String) == text
        guard matches else { return nil }
        // Use the typed NSRect return ABI; perform(_:) is reserved above for object-valued AX attributes.
        if let element = object as? any NSAccessibilityProtocol { return element.accessibilityFrame() }
        return (object as? any NSAccessibilityElementProtocol)?.accessibilityFrame()
    }
}
#endif
