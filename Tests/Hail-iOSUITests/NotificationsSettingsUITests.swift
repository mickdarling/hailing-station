import XCTest

/// Only the explicit Check access tap reads system settings. No request, registration or notification is posted.
final class NotificationsSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Notifications Settings checks run only on an owned, unconfigured simulator.")
        }
    }

    @MainActor
    func testAccessStartsUncheckedAndOnlyAnExplicitCheckReadsThenRetainsItsSnapshot() {
        let app = XCUIApplication()
        launchNotificationsShell(app)
        openNotifications(app)
        let status = app.staticTexts["settings.notifications.access-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Not checked")
        captureNotifications(app, named: "notifications-not-checked")
        let check = app.buttons["settings.notifications.check"]
        revealNotifications(check, in: app)
        check.tap()
        let read = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Not checked"), object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [read], timeout: 5), .completed)
        let snapshot = status.label
        XCTAssertTrue(["Not determined", "Denied", "Authorized", "Provisional", "Temporary access",
                       "Unknown system status"].contains(snapshot), "Never assume simulator authorization defaults")
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: check)
        XCTAssertEqual(XCTWaiter().wait(for: [complete], timeout: 5), .completed)
        XCTAssertTrue(check.isEnabled)
        captureNotifications(app, named: "notifications-last-check")
        let back = app.navigationBars["Notifications and updates"].buttons["Settings"]
        waitForNotificationsElement(back)
        back.tap()
        XCTAssertTrue(app.navigationBars["Notifications and updates"].waitForNonExistence(timeout: 5))
        openNotifications(app)
        XCTAssertEqual(status.label, snapshot, "The same root-owned reading survives navigation")
    }

    @MainActor
    func testLargestTypeAndLandscapeKeepReadOnlyAccessAndHostScopeReachable() {
        let app = XCUIApplication()
        launchNotificationsShell(app, arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openNotifications(app)
        let status = app.staticTexts["settings.notifications.access-status"]
        revealNotifications(status, in: app, towardTop: true)
        XCTAssertEqual(status.label, "Not checked")
        captureNotifications(app, named: "notifications-largest-type")
        XCUIDevice.shared.orientation = .landscapeLeft
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if frame.width > frame.height { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        let check = app.buttons["settings.notifications.check"]
        revealNotifications(check, in: app)
        assertNotificationsWidth(check, in: app)
        let host = app.staticTexts["settings.notifications.host-managed"]
        revealNotifications(host, in: app)
        assertNotificationsWidth(host, in: app)
        waitForNotificationsElement(app.navigationBars["Notifications and updates"].buttons["Settings"])
        captureNotifications(app, named: "notifications-largest-type-landscape")
        revealNotifications(status, in: app, towardTop: true)
        XCTAssertEqual(status.label, "Not checked", "Layout and reading host help must not perform an OS query")
    }
}
