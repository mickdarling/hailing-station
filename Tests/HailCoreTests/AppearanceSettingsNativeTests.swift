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

        await render(host)
        #expect(visibleText(host).joined(separator: " ").contains("14 points, default"))
        try export(host, named: "appearance-mac-light-default")

        preferences.apply(.larger)
        await render(host)
        #expect(visibleText(host).joined(separator: " ").contains("16 points"))
        try export(host, named: "appearance-mac-light-larger")

        preferences.apply(.reset)
        host.rootView = scene(preferences, scheme: .dark)
        await render(host)
        #expect(visibleText(host).joined(separator: " ").contains("14 points, default"))
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

    private func visibleText(_ value: Any) -> [String] {
        guard let object = value as? NSObject else { return [] }
        func attribute(_ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        let own = [attribute("accessibilityLabel") as? String,
                   attribute("accessibilityValue") as? String].compactMap { $0 }
        return own + ((attribute("accessibilityChildren") as? [Any]) ?? []).flatMap(visibleText)
    }
}
#endif
