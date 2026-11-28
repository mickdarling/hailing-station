#if STATION_UI_FIXTURES && os(iOS)
import CoreImage
import HailCore
import XCTest

/// The redesigned iPhone station paints its surface up to the top edge (#1397). iOS only.
extension ShellWindowStationStateScreenshotTests {
    @MainActor
    func testIPhoneStationBackgroundReachesTopEdge() throws {
        try XCTSkipUnless(device == "iphone", "The top-edge background belongs to the phone tabs.")
        let app = launchStation(shellEnabled: true, arguments: ["-seed-station-screen", "offline",
                                                                 "-seed-conversation", "4"],
                                fixtureAppearance: .light)
        XCUIDevice.shared.orientation = .portrait
        let previous = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = previous }

        let swatch = StationTheme.astra[.elevatedSurface]
        for style in [XCUIDevice.Appearance.light, .dark] {
            setScreenshotAppearance(style, in: app)
            // The native navigation bar on the adjacent tab starts at this phone's top safe-area boundary.
            choose("sessions", in: app)
            let bar = app.navigationBars["Sessions"]
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            let safeTop = bar.frame.minY
            XCTAssertGreaterThan(safeTop, 0)
            choose("station", in: app)
            XCTAssertGreaterThanOrEqual(destinationPicker(in: app).frame.minY, safeTop)

            let screenshot = XCUIScreen.main.screenshot()
            add(XCTAttachment(screenshot: screenshot))
            let expected = style == .dark ? swatch.dark : swatch.light
            try assertTopPixel(in: screenshot, matches: expected)
        }
    }

    @MainActor
    private func assertTopPixel(in screenshot: XCUIScreenshot, matches expected: UInt32) throws {
        let image = CIImage(cgImage: try XCTUnwrap(screenshot.image.cgImage))
        // Core Image measures from the bottom. Sample the top row clear of the rounded corners and camera.
        let pixel = CGRect(x: floor(image.extent.width / 4), y: image.extent.maxY - 1, width: 1, height: 1)
        var rgba = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        CIContext().render(image, toBitmap: &rgba, rowBytes: 4, bounds: pixel, format: .RGBA8, colorSpace: space)
        for (channel, shift) in [16, 8, 0].enumerated() {
            let expectedByte = Int((expected >> shift) & 0xFF)
            XCTAssertEqual(Int(rgba[channel]), expectedByte, accuracy: 1, "Top edge RGB channel \(channel)")
        }
    }
}
#endif
