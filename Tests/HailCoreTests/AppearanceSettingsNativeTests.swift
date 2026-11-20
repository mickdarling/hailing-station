#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore

/// Hosts only the Appearance view and its isolated preference owner. No station, transport or audio owner exists.
@Suite("Native Appearance settings", .serialized)
@MainActor
struct AppearanceSettingsNativeTests {
    @Test func theNativeViewObservesChangesAndCanExportSyntheticScreenshots() async throws {
        let suite = "AppearanceSettingsNativeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ConversationAppearancePreferences(defaults: defaults, platform: .mac)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: scene(preferences, scheme: .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        // This in-process host publishes selectable preview cells, not the static SwiftUI value label. Assert
        // actual rendered growth/reset here; iOS UI covers value labels. Physical Mac VoiceOver remains unqualified.
        await render(host)
        #expect(preferences.state.size == 14)
        let initial = try renderedPreviewFrame(host)
        try export(host, named: "appearance-mac-light-default")

        preferences.apply(.larger)
        await render(host)
        #expect(preferences.state.size == 16)
        let larger = try renderedPreviewFrame(host)
        #expect(larger.height > initial.height)
        try export(host, named: "appearance-mac-light-larger")

        preferences.apply(.reset)
        host.rootView = scene(preferences, scheme: .dark)
        await render(host)
        #expect(preferences.state.size == 14)
        let reset = try renderedPreviewFrame(host)
        #expect(abs(reset.height - initial.height) < 0.5)
        print("Appearance preview heights: default=\(initial.height), larger=\(larger.height), reset=\(reset.height)")
        try export(host, named: "appearance-mac-dark-default")
    }

    private func scene(_ preferences: ConversationAppearancePreferences, scheme: ColorScheme) -> AnyView {
        AnyView(AppearanceSettingsView().environment(preferences).environment(\.colorScheme, scheme)
            .environment(\.accessibilityEnabled, true))
    }

    private func render(_ host: NSView) async {
        for _ in 0..<4 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func export(_ host: NSView, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["HAIL_APPEARANCE_SCREENSHOT_DIR"],
              !directory.isEmpty else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(name).appendingPathExtension("png"), options: .atomic)
    }

    private func renderedPreviewFrame(_ value: Any) throws -> NSRect {
        var traversal = AppearanceAccessibilityTraversal()
        _ = traversal.read(value)
        if !traversal.diagnostics.isEmpty { print(traversal.diagnostics.joined(separator: "\n")) }
        let frame = try #require(traversal.previewFrame, "The actual authored preview sentence must be accessible.")
        try #require(frame.width > 0 && frame.height > 0, "The rendered preview must have a nonempty frame.")
        return frame
    }
}

/// Walk navigation-order and backing children without requiring NSObject subclassing or counting duplicates.
/// The observed in-process host exposes the selectable preview's native Cell, whose typed AX frame is measurable.
@MainActor
private struct AppearanceAccessibilityTraversal {
    private var seen: Set<ObjectIdentifier> = []
    private let diagnostic = ProcessInfo.processInfo.environment["HAIL_APPEARANCE_AX_DIAGNOSTIC"] == "1"
    private(set) var diagnostics: [String] = []
    private(set) var previewFrame: NSRect?

    mutating func read(_ value: Any) -> [String] {
        guard let object = value as? any NSObjectProtocol else { return [] }
        guard seen.count < 512, seen.insert(ObjectIdentifier(object as AnyObject)).inserted else { return [] }
        let full = object as? any NSAccessibilityProtocol
        let own: [Any?]
        let navigation: [Any], regular: [Any], contents: [Any]
        if let full {
            own = [full.accessibilityLabel(), full.accessibilityValue(), full.accessibilityTitle(),
                   full.accessibilityValueDescription()]
            navigation = (full.accessibilityChildrenInNavigationOrder() ?? []).map { $0 as Any }
            regular = full.accessibilityChildren() ?? []
            contents = full.accessibilityContents() ?? []
        } else {
            own = [attribute("accessibilityLabel", on: object), attribute("accessibilityValue", on: object),
                   attribute("accessibilityTitle", on: object), attribute("accessibilityValueDescription", on: object)]
            navigation = (attribute("accessibilityChildrenInNavigationOrder", on: object) as? [Any]) ?? []
            regular = (attribute("accessibilityChildren", on: object) as? [Any]) ?? []
            contents = (attribute("accessibilityContents", on: object) as? [Any]) ?? []
        }
        let text = own.compactMap(Self.text)
        if text.contains("Let's make this easier to read."), let full {
            previewFrame = full.accessibilityFrame()
        }
        if diagnostic, diagnostics.count < 64 {
            let summary = text.joined(separator: " | ").prefix(160)
            diagnostics.append("AX type=\(type(of: value)) full=\(full != nil) nav=\(navigation.count) "
                + "children=\(regular.count) contents=\(contents.count) text=\(summary)")
        }
        var result = text
        for child in navigation + regular + contents { result += read(child) }
        return result
    }

    private func attribute(_ name: String, on object: any NSObjectProtocol) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        // Every selected getter returns an object; never use perform(_:) for an NSRect or other struct getter.
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func text(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }
}
#endif
