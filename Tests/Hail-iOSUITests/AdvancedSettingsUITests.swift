import XCTest

/// Changes only the existing diagnostics opt-in on an unconfigured owned simulator, never an audio action.
final class AdvancedSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Advanced settings checks run only on an owned, unconfigured simulator.")
        }
    }

    @MainActor
    func testDiagnosticsUsesTheSameOwnerAsTheExistingStationSwitch() {
        let app = XCUIApplication()
        launchShell(app)
        openAdvanced(app)
        let toggle = app.switches["settings.advanced.diagnostics-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        let status = app.staticTexts["settings.advanced.diagnostics-status"]
        XCTAssertTrue(status.label.hasPrefix("Off."))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(status.label.contains("No connected Mac is collecting"))
        capture(app, named: "advanced-diagnostics-enabled-no-collector")
        let back = app.navigationBars["Advanced and diagnostics"].buttons["Settings"]
        waitUntilHittable(back)
        back.tap()
        tapSection("station", in: app)
        let original = app.switches["station.diagnostics-toggle"]
        reveal(original, in: app)
        XCTAssertEqual(original.value as? String, "1", "Both controls observe the same root-owned log")
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(original.value as? String, "0")
        openAdvanced(app)
        XCTAssertEqual(toggle.value as? String, "0", "The old control updates the new page")
        XCTAssertTrue(status.label.hasPrefix("Off."))
        visitTool("settings.advanced.labs", title: "Labs", in: app)
        visitTool("settings.advanced.turn-taking", title: "Turn-taking", in: app)
    }

    @MainActor
    func testLargestDynamicTypeAndLandscapeKeepToolsAndBuildReachable() {
        let app = XCUIApplication()
        launchShell(app, extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openAdvanced(app)
        let toggle = app.switches["settings.advanced.diagnostics-toggle"]
        reveal(toggle, in: app, towardTop: true)
        XCTAssertEqual(toggle.value as? String, "0")
        capture(app, named: "advanced-largest-type")
        XCUIDevice.shared.orientation = .landscapeLeft
        // Keep XCTest geometry reads on the main actor; block predicates may run off that actor.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if frame.width > frame.height { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        let build = app.staticTexts["settings.advanced.build"]
        reveal(build, in: app)
        XCTAssertTrue(build.label.hasPrefix("Version "))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(build.frame.width, 0)
        XCTAssertGreaterThanOrEqual(build.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(build.frame.maxX, window.maxX)
        waitUntilHittable(app.navigationBars["Advanced and diagnostics"].buttons["Settings"])
        XCTAssertFalse(app.descendants(matching: .any)["station.build-info"].firstMatch.exists,
                       "Settings does not expose the hidden Station footer identifier")
        capture(app, named: "advanced-largest-type-landscape")
    }
}
