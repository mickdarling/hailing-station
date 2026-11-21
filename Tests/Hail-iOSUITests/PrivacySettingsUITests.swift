import XCTest

/// Read-only navigation on an unconfigured simulator. No preference, privacy, listening or permission action.
final class PrivacySettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Privacy Settings navigation runs only on an owned, unconfigured simulator.")
        }
    }

    @MainActor
    func testPrivacyShowsUnknownWithoutAHostAndReturnsToTheStation() throws {
        let app = XCUIApplication()
        launchPrivacyShell(app)
        openPrivacy(app)
        let control = app.switches["settings.privacy.switch"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertFalse(control.isEnabled)
        XCTAssertEqual(control.value as? String, "Recording may be on")
        capturePrivacy(app, named: "privacy-unconfigured")
        let stop = app.buttons["settings.privacy.stop-listening"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(stop.isEnabled)
        let initial = try privacyOverheardReading(app)
        closePrivacyToSettings(app)
        openPrivacy(app)
        XCTAssertEqual(try privacyOverheardReading(app), initial, "Navigation preserves the existing preference/scope")
        closePrivacyToSettings(app)
        tapPrivacySection("station", in: app)
        XCTAssertTrue(privacyElement("station.tools", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testPrivacyKeepsControlsAndBackReachableAtLargestTypeInLandscape() throws {
        let app = XCUIApplication()
        launchPrivacyShell(app, arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openPrivacy(app)
        let show = app.switches["settings.privacy.overheard-show"]
        revealPrivacyElement(show, in: app)
        let initial = try XCTUnwrap(show.value as? String)
        assertPrivacyWidth(show, in: app)
        capturePrivacy(app, named: "privacy-largest-type")
        XCUIDevice.shared.orientation = .landscapeLeft
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if frame.width > frame.height { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        revealPrivacyElement(show, in: app)
        XCTAssertEqual(try XCTUnwrap(show.value as? String), initial, "Layout changes preserve the saved preference")
        assertPrivacyWidth(show, in: app)
        waitForPrivacyElement(app.navigationBars["Privacy"].buttons["Settings"])
        capturePrivacy(app, named: "privacy-largest-type-landscape")
    }
}
