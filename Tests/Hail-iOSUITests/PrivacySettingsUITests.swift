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
    func testPrivacyShowsUnknownWithoutAHostAndReturnsToTheStation() {
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
        let requested = privacyElement("settings.privacy.overheard-requested", in: app)
        revealPrivacyElement(requested, in: app)
        XCTAssertTrue(requested.label.contains("Off"))
        let back = app.navigationBars["Privacy"].buttons["Settings"]
        waitForPrivacyElement(back)
        back.tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForNonExistence(timeout: 5))
        waitForPrivacyElement(app.buttons["station.settings.privacy"])
        tapPrivacySection("station", in: app)
        XCTAssertTrue(privacyElement("station.tools", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testPrivacyKeepsControlsAndBackReachableAtLargestTypeInLandscape() {
        let app = XCUIApplication()
        launchPrivacyShell(app, arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openPrivacy(app)
        let show = app.switches["settings.privacy.overheard-show"]
        revealPrivacyElement(show, in: app)
        XCTAssertEqual(show.value as? String, "0", "Navigation must not enable overheard remarks")
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
        XCTAssertEqual(show.value as? String, "0")
        assertPrivacyWidth(show, in: app)
        waitForPrivacyElement(app.navigationBars["Privacy"].buttons["Settings"])
        capturePrivacy(app, named: "privacy-largest-type-landscape")
    }
}
