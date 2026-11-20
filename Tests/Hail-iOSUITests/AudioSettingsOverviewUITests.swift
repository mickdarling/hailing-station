import XCTest

/// Unconfigured simulator navigation only: no session, route, capture or permission action is tapped.
final class AudioSettingsOverviewUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Audio overview navigation runs only on an owned, unconfigured simulator.")
        }
    }

    @MainActor
    func testAudioOverviewUsesExistingToolWithoutActivatingSession() {
        let app = XCUIApplication()
        launchShell(app)
        openOverview(app)
        assertInactiveOverview(app)
        capture(app, named: "audio-overview-inactive")
        let tools = element("settings.audio.tools", in: app)
        reveal(tools, in: app)
        tools.tap()
        let toolTitle = app.navigationBars["Audio session"]
        XCTAssertTrue(toolTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Inactive"].waitForExistence(timeout: 5))
        toolTitle.buttons.firstMatch.tap()
        XCTAssertTrue(toolTitle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Audio"].waitForExistence(timeout: 5))
        assertInactiveOverview(app)
        app.navigationBars["Audio"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("station.settings.audio", in: app).isHittable)
        section("station", in: app).tap()
        XCTAssertTrue(element("station.tools", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testAudioOverviewSupportsLargestDynamicTypeAndLandscape() {
        let app = XCUIApplication()
        launchShell(app, extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openOverview(app)
        let input = element("settings.audio.input", in: app)
        reveal(input, in: app, towardTop: true)
        XCTAssertTrue(input.label.contains("Audio inactive"))
        assertFitsWidth(input, in: app)
        capture(app, named: "audio-overview-largest-type")
        let tools = element("settings.audio.tools", in: app)
        reveal(tools, in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let wide = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height },
            object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [wide], timeout: 5), .completed)
        reveal(tools, in: app)
        assertFitsWidth(tools, in: app)
        XCTAssertTrue(app.navigationBars["Audio"].buttons.firstMatch.isHittable, "Back stays reachable")
        capture(app, named: "audio-overview-largest-type-landscape")
    }

    @MainActor
    private func launchShell(_ app: XCUIApplication, extraArguments: [String] = []) {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = ["-reset-station-state"]
            app.launch()
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        app.launchArguments = ["-reset-station-state"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("settings.audio.overview", in: app).exists, "Default-off station is unchanged")
        let labs = app.buttons["Labs"]
        reveal(labs, in: app)
        labs.tap()
        if !app.navigationBars["Labs"].waitForExistence(timeout: 3), labs.isHittable { labs.tap() }
        XCTAssertTrue(app.navigationBars["Labs"].waitForExistence(timeout: 5))
        let toggle = app.switches["station.redesign.shell"]
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.terminate()
        app.launchArguments = extraArguments
        app.launch()
        XCTAssertTrue(section("settings", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    private func openOverview(_ app: XCUIApplication) {
        section("settings", in: app).tap()
        let audio = element("station.settings.audio", in: app)
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        audio.tap()
        XCTAssertTrue(app.navigationBars["Audio"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.audio.overview", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("station.connection", in: app).exists, "The mounted Station stays hidden")
        XCTAssertFalse(app.buttons["Activate"].exists, "Session actions require opening the separate tool")
    }

    @MainActor
    private func assertInactiveOverview(_ app: XCUIApplication) {
        let input = element("settings.audio.input", in: app)
        reveal(input, in: app, towardTop: true)
        XCTAssertTrue(input.label.contains("Audio inactive"))
        let output = element("settings.audio.output", in: app)
        reveal(output, in: app)
        XCTAssertTrue(output.label.contains("System output"))
        XCTAssertFalse(app.buttons["Activate"].exists)
    }

    @MainActor
    private func section(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let prefix = UIDevice.current.userInterfaceIdiom == .pad ? "station.section." : "station.tab."
        return element(prefix + name, in: app)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        let limit = app.windows.firstMatch.frame.maxY - 120
        for _ in 0..<8 where !(element.exists && element.isHittable && element.frame.maxY < limit) {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func assertFitsWidth(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = app.windows.firstMatch.frame
        XCTAssertGreaterThan(element.frame.width, 0)
        XCTAssertGreaterThanOrEqual(element.frame.minX, viewport.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, viewport.maxX)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
