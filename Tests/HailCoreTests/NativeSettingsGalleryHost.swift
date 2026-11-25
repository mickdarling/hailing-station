#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import Testing

struct NativeSettingsGalleryImage {
    let data: Data
    let pixelsWide: Int
    let pixelsHigh: Int
    let opaqueSampleFraction: Double
}

/// Native NSHostingView content only, never a normal station window, audio owner or application bootstrap.
@MainActor
final class NativeSettingsGalleryHost {
    private let hosting: NSHostingView<AnyView>
    private let window: TestHostWindow
    private let size: NSSize

    init(scene: AnyView, width: CGFloat, scheme: ColorScheme, typeSize: DynamicTypeSize) {
        size = NSSize(width: width, height: 900)
        window = TestHostWindow(size: size)
        hosting = NSHostingView(rootView: AnyView(NavigationStack { scene }
            .frame(width: width, height: 900)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.accessibilityEnabled, true)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.mount(hosting)
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
    }

    func render() async {
        for _ in 0..<4 {
            hosting.setFrameSize(size)
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            hosting.needsDisplay = true
            hosting.displayIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func png() throws -> NativeSettingsGalleryImage {
        let bounds = hosting.bounds
        try #require(window.isVisible, "Capture only the mounted synthetic fixture window")
        try #require(abs(bounds.width - size.width) < 0.5 && abs(bounds.height - size.height) < 0.5,
                     "Native Form intrinsic sizing must not replace the requested viewport")
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.cacheDisplay(in: bounds, to: bitmap)
        let backing = hosting.convertToBacking(bounds).integral
        try #require(bitmap.pixelsWide == Int(backing.width) && bitmap.pixelsHigh == Int(backing.height),
                     "PNG dimensions must match the fixed viewport at this fixture's backing scale")
        let opaqueSampleFraction = try readOpaqueSampleFraction(bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try #require(!png.isEmpty)
        return NativeSettingsGalleryImage(data: png, pixelsWide: bitmap.pixelsWide,
                                          pixelsHigh: bitmap.pixelsHigh, opaqueSampleFraction: opaqueSampleFraction)
    }

    private func readOpaqueSampleFraction(_ bitmap: NSBitmapImageRep) throws -> Double {
        var samples = 0, opaque = 0
        // Sample alpha only. Content, contrast and sparse native layouts need independent visual inspection.
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 225)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 225)) {
                let color = try #require(bitmap.colorAt(x: x, y: y))
                samples += 1
                if color.alphaComponent >= 0.999 { opaque += 1 }
            }
        }
        try #require(samples > 0)
        try #require(opaque == samples, "Every sampled canvas pixel must be opaque, including behind Form text")
        return Double(opaque) / Double(samples)
    }

    func finish() { window.close() }
}
#endif
