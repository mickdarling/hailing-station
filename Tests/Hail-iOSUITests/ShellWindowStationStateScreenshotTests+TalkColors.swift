#if STATION_UI_FIXTURES && os(iOS)
import CoreImage
import HailCore
import XCTest

extension ShellWindowStationStateScreenshotTests {
    @MainActor
    func assertTalkColors(in screenshot: XCUIScreenshot, state: StationTranscriptSeed,
                          appearance: XCUIDevice.Appearance) throws {
        // Landscape screenshots can store rotated pixels with the display orientation in the PNG metadata.
        let image = try XCTUnwrap(CIImage(data: screenshot.pngRepresentation,
                                          options: [.applyOrientationProperty: true]))
        // Stay inside the rounded control so the dock background cannot stand in for its lettering.
        let region = image.extent.insetBy(dx: min(image.extent.width / 5, image.extent.height / 2),
                                          dy: image.extent.height / 5).integral
        let width = Int(region.width), height = Int(region.height)
        XCTAssertGreaterThan(width * height, 0)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        CIContext().render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: region,
                           format: .RGBA8, colorSpace: space)

        let fill: StationTheme.Role = state.dock.isEnabled ? (state == .recording ? .stateLive : .accentTalk)
            : .textSecondary
        let ink: StationTheme.Role = state.dock.isEnabled ? .brandOnBrand : .elevatedSurface
        func count(_ role: StationTheme.Role, columns: Range<Int>) -> Int {
            let pair = StationTheme.astra[role]
            let rgb = appearance == .dark ? pair.dark : pair.light
            let red = Int(rgb >> 16), green = Int((rgb >> 8) & 255), blue = Int(rgb & 255)
            return stride(from: 0, to: pixels.count, by: 4).filter { offset in
                let column = (offset / 4) % width
                return columns.contains(column) && pixels[offset + 3] == 255 && abs(Int(pixels[offset]) - red) <= 3
                    && abs(Int(pixels[offset + 1]) - green) <= 3 && abs(Int(pixels[offset + 2]) - blue) <= 3
            }.count
        }
        XCTAssertGreaterThan(count(fill, columns: 0..<width), width * height / 4, "\(state) fill in \(appearance)")
        XCTAssertGreaterThan(count(ink, columns: 0..<width), 20, "\(state) label in \(appearance)")
        // The English fixture centers an icon-leading label. Sample right of center by half the button height
        // so even an icon centered by itself cannot contribute to the title check.
        let titleStart = Int(ceil(region.width / 2 + image.extent.height / 2))
        XCTAssertLessThan(titleStart, width)
        XCTAssertGreaterThan(count(ink, columns: min(titleStart, width)..<width), 20,
                             "\(state) title foreground in \(appearance)")
    }
}
#endif
