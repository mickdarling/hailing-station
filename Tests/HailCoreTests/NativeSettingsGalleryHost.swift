#if os(macOS)
import AppKit
import SwiftUI
import Testing

struct NativeSettingsGalleryImage {
    let data: Data
    let pixelsWide: Int
    let pixelsHigh: Int
}

/// Native NSHostingView content only, never a normal station window, audio owner or application bootstrap.
@MainActor
final class NativeSettingsGalleryHost {
    private let hosting: NSHostingView<AnyView>
    private let window: NSWindow

    init(scene: AnyView, width: CGFloat, scheme: ColorScheme, typeSize: DynamicTypeSize) {
        _ = NSApplication.shared
        hosting = NSHostingView(rootView: AnyView(NavigationStack { scene }
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.accessibilityEnabled, true)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
    }

    func render() async {
        for _ in 0..<4 {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func png() throws -> NativeSettingsGalleryImage {
        let bounds = hosting.bounds
        try #require(bounds.width > 0 && bounds.height > 0, "The native fixture must have visible content bounds")
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.cacheDisplay(in: bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && !png.isEmpty)
        return NativeSettingsGalleryImage(data: png, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh)
    }

    func finish() { window.close() }
}
#endif
