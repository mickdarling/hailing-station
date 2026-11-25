import XCTest

/// The real flag, station and navigation. The Mac test configuration has a separate bundle ID and preferences.
final class StationThemeScreenshotUITests: XCTestCase, ShellWindowUITestSupport {
    @MainActor
    func testStationAndEachShellSectionInBothAppearances() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Station screenshots use simulators.")
        #else
        continueAfterFailure = true // Capture the remaining sections even if one detail is missing.
        let appearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = appearance }

        XCUIDevice.shared.appearance = .light
        let app = launchStation(shellEnabled: false)
        screen("station.connection", named: "station-off-light", in: app)
        XCTAssertFalse(section("devices", in: app).exists)
        try setShell(true, in: app)
        app.terminate()
        app.launchArguments = baseArguments
        try captureShellAppearances(in: app)
        app.launch()
        _ = destinationPicker(in: app)
        XCTAssertFalse(section("devices", in: app).exists)
        #endif
    }
}

private extension StationThemeScreenshotUITests {
    @MainActor
    func captureShellAppearances(in app: XCUIApplication) throws {
        for style in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = style
            app.launch()
            visitSections(in: app, appearance: style == .light ? "light" : "dark")
            if style == .dark { try setShell(false, in: app) }
            app.terminate()
        }
    }

    @MainActor
    func visitSections(in app: XCUIApplication, appearance: String) {
        let sections = [("station", "station.connection"), ("sessions", "shell.sessions.placeholder"),
                        ("devices", "station.devices.mac-setup"), ("settings", "station.settings.appearance")]
        for (name, identifier) in sections {
            let item = section(name, in: app)
            let attachment = "\(name)-\(appearance)"
            guard item.waitForExistence(timeout: 10), item.isHittable else {
                attachScreen("\(attachment)-missing-navigation", in: app)
                XCTFail("Cannot reach \(name)")
                continue
            }
            activate(item)
            screen(identifier, named: attachment, in: app)
        }
    }

    @MainActor
    func setShell(_ enabled: Bool, in app: XCUIApplication) throws {
        let all = app.descendants(matching: .any)
        let labs = enabled ? all["Labs"].firstMatch : all["station.settings.labs"].firstMatch
        try revealLabsControl(labs, in: app)
        activate(labs)
        #if os(macOS)
        let toggle = shellToggle(in: app)
        try revealLabsControl(toggle, in: app)
        activate(toggle)
        #else
        // A tap during deceleration can stop the scroll before the Labs link receives it.
        if !app.navigationBars["Labs"].waitForExistence(timeout: 3), labs.exists, labs.isHittable { activate(labs) }
        let toggle = shellToggle(in: app)
        try revealLabsControl(toggle, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        #endif
        XCTAssertTrue(all["station.redesign.shell.pending"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func revealLabsControl(_ element: XCUIElement, in app: XCUIApplication) throws {
        let window = app.windows.firstMatch
        for _ in 0..<8 {
            let viewport = window.frame
            let frame = element.exists ? element.frame : .zero
            if element.exists && element.isHittable && frame.maxY < viewport.maxY - 45 { return }
            let horizontal = element.exists ? min(max((frame.midX - viewport.minX) / viewport.width, 0.1), 0.9) : 0.7
            #if os(macOS)
            let point = window.coordinate(withNormalizedOffset: CGVector(dx: horizontal, dy: 0.65))
            point.scroll(byDeltaX: 0, deltaY: -220)
            #else
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: horizontal, dy: 0.7))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: horizontal, dy: 0.35))
            start.press(forDuration: 0.01, thenDragTo: end)
            #endif
        }
        _ = try XCTUnwrap(element.exists && element.isHittable ? element : nil, "Cannot reach \(element)")
    }
}
