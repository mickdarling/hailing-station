#if os(macOS)
import AppKit
import SwiftUI
import Testing
import HailCore
@testable import StationTalkTestSupport

@MainActor
struct VoiceDockButtonSnapshotTests {
    enum State: CaseIterable { case idle, disabled, capturing }

    @Test(arguments: [ColorScheme.light, .dark], State.allCases)
    func talkButtonInANonKeyWindow(scheme: ColorScheme, state: State) async throws {
        let session = DestinationLabel(hostName: "Fixture", targetName: "Session", targetKind: "tmux", targetID: "1")
        let activity = TalkActivity(phase: state == .capturing ? .recording : .idle,
                                    sendPending: state == .disabled, interrupting: false)
        let dock = VoiceDockState.resolve(talk: activity, destination: .confirmed(session),
                                          accessories: DockAccessories(escape: false, privacy: false, paste: false))
        let view = VoiceDockView(state: dock, caption: nil, onIntent: { _ in })
            .environment(MountedTalkProbe())
            .environment(\.colorScheme, scheme)
        let bitmap = try await snapshot(view, scheme: scheme)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(png, named: "mac-inactive-\(scheme)-\(state).png")

        let fill: StationTheme.Role = switch state {
        case .idle: .accentTalk
        case .disabled: .textSecondary
        case .capturing: .stateLive
        }
        let ink: StationTheme.Role = state == .disabled ? .elevatedSurface : .brandOnBrand
        expectButtonPixels(in: bitmap, fill: fill, ink: ink, scheme: scheme)
    }

    private func snapshot(_ view: some View, scheme: ColorScheme) async throws -> NSBitmapImageRep {
        let size = CGSize(width: 480, height: 150)
        let window = TestHostWindow(size: size)
        defer { window.close() }
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.mount(host)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        #expect(!window.isKeyWindow)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // AppKit captures in the display profile. Convert the bitmap before reading its channel values.
        return try #require(bitmap.converting(to: .sRGB, renderingIntent: .relativeColorimetric))
    }

    private func expectButtonPixels(in bitmap: NSBitmapImageRep, fill: StationTheme.Role, ink: StationTheme.Role,
                                    scheme: ColorScheme) {
        func matches(_ role: StationTheme.Role, x: Int, y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y) else { return false }
            let swatch = StationTheme.astra[role]
            let rgb = scheme == .light ? swatch.light : swatch.dark
            let red = CGFloat(rgb >> 16)
            let green = CGFloat((rgb >> 8) & 255)
            let blue = CGFloat(rgb & 255)
            return color.alphaComponent > 0.99 && abs(color.redComponent * 255 - red) <= 4
                && abs(color.greenComponent * 255 - green) <= 4 && abs(color.blueComponent * 255 - blue) <= 4
        }
        // Locate the trailing edge of the fill on each scanline of the leading control.
        // Sample inside that edge so the white dock surface can't stand in for white lettering.
        let left = bitmap.pixelsWide / 12
        var filledLines = 0, inkPixels = 0
        for y in 0..<bitmap.pixelsHigh where matches(fill, x: left, y: y) {
            let scanline = left..<(bitmap.pixelsWide / 2)
            guard let right = scanline.last(where: { matches(fill, x: $0, y: y) }),
                  right - left > bitmap.pixelsWide / 4 else { continue }
            filledLines += 1
            for x in stride(from: left, to: right, by: 2) where matches(ink, x: x, y: y) { inkPixels += 1 }
        }
        #expect(filledLines >= 30)
        #expect(inkPixels >= 20)
    }
}
#endif
