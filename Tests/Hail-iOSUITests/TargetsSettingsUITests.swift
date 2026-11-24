import XCTest

/// Read-only navigation on an unconfigured simulator; no connection, setup save, target or audio action.
final class TargetsSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Targets Settings navigation runs only on an owned, unconfigured simulator.")
        }
    }

    @MainActor
    func testTargetsKeepsSetupExplicitAndReturnsToStationWithoutOpeningItsBrowser() {
        let app = XCUIApplication()
        launchTargetsShell(app)
        openTargets(app)
        XCTAssertTrue(app.staticTexts["settings.targets.no-macs"].waitForExistence(timeout: 5))
        let current = targetsElement("settings.targets.destination", in: app)
        XCTAssertTrue(current.label.contains("Choose a destination"))
        captureTargets(app, named: "targets-unconfigured")
        let setup = app.buttons["settings.targets.mac-setup"]
        revealTargets(setup, in: app)
        setup.tap()
        XCTAssertTrue(app.navigationBars["Mac Setup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Add a Mac address to begin."].waitForExistence(timeout: 5))
        let back = app.navigationBars["Mac Setup"].buttons["Targets"]
        waitForTargetsElement(back)
        back.tap()
        XCTAssertTrue(app.navigationBars["Mac Setup"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.targets.no-macs"].waitForExistence(timeout: 5))
        let choose = app.buttons["settings.targets.choose"]
        revealTargets(choose, in: app, towardTop: true)
        choose.tap()
        XCTAssertTrue(targetsElement("settings.targets.page", in: app).waitForNonExistence(timeout: 5))
        let destination = app.buttons["station.destination"]
        revealTargets(destination, in: app, towardTop: true)
        XCTAssertFalse(app.navigationBars["Choose a destination"].waitForExistence(timeout: 1),
                       "Only Station navigation occurs; the visible destination control needs its own explicit tap")
    }

    @MainActor
    func testLargestDynamicTypeAndLandscapeKeepSetupAndNavigationReachable() {
        let app = XCUIApplication()
        launchTargetsShell(app, arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openTargets(app)
        let choose = app.buttons["settings.targets.choose"]
        revealTargets(choose, in: app, towardTop: true)
        assertTargetsWidth(choose, in: app)
        captureTargets(app, named: "targets-largest-type")
        XCUIDevice.shared.orientation = .landscapeLeft
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if frame.width > frame.height { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        let setup = app.buttons["settings.targets.mac-setup"]
        revealTargets(setup, in: app)
        assertTargetsWidth(setup, in: app)
        waitForTargetsElement(app.navigationBars["Targets"].buttons["Settings"])
        XCTAssertTrue(app.staticTexts["settings.targets.no-macs"].exists)
        captureTargets(app, named: "targets-largest-type-landscape")
    }
}
