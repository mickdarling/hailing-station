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
        let tools = app.buttons["settings.audio.tools"]
        reveal(tools, in: app)
        tools.tap()
        let toolTitle = app.navigationBars["Audio session"]
        XCTAssertTrue(toolTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Inactive"].waitForExistence(timeout: 5))
        let backToOverview = toolTitle.buttons["Audio"]
        waitUntilHittable(backToOverview)
        backToOverview.tap()
        XCTAssertTrue(toolTitle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Audio"].waitForExistence(timeout: 5))
        assertInactiveOverview(app)
        let backToSettings = app.navigationBars["Audio"].buttons["Settings"]
        waitUntilHittable(backToSettings)
        backToSettings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        waitUntilHittable(app.buttons["station.settings.audio"])
        tapSection("station", in: app)
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
        let tools = app.buttons["settings.audio.tools"]
        reveal(tools, in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        // Query XCTest geometry on the main actor; a block predicate can be evaluated off that actor.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if frame.width > frame.height { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        reveal(tools, in: app)
        assertFitsWidth(tools, in: app)
        waitUntilHittable(app.navigationBars["Audio"].buttons["Settings"])
        capture(app, named: "audio-overview-largest-type-landscape")
    }

}
