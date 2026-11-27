import XCTest

extension NotificationsSettingsUITests {
    @MainActor
    func launchNotificationsShell(_ app: XCUIApplication, arguments: [String] = []) {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = ["-reset-station-state"]
            app.launch()
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        app.launchArguments = ClassicStationFixture.resetArguments
        app.launch()
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["settings.notifications.access-status"].exists)
        let labs = app.buttons["Labs"]
        revealNotifications(labs, in: app)
        labs.tap()
        if !app.navigationBars["Labs"].waitForExistence(timeout: 3), labs.isHittable { labs.tap() }
        XCTAssertTrue(app.navigationBars["Labs"].waitForExistence(timeout: 5))
        let toggle = app.switches["station.redesign.shell"]
        revealNotifications(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.terminate()
        app.launchArguments = arguments
        app.launch()
    }

    @MainActor
    func openNotifications(_ app: XCUIApplication) {
        let settings = UIDevice.current.userInterfaceIdiom == .pad
            ? app.staticTexts["station.section.settings"].firstMatch : app.buttons["station.tab.settings"].firstMatch
        waitForNotificationsElement(settings)
        settings.tap()
        let entry = app.buttons["settings.notifications.entry"]
        revealNotifications(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Notifications and updates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.notifications.access-status"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["station.connection"].firstMatch.exists)
    }

    @MainActor
    func waitForNotificationsElement(_ item: XCUIElement) {
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: item)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 5), .completed)
        XCTAssertTrue(item.isHittable)
    }

    @MainActor
    func revealNotifications(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        let window = app.windows.firstMatch
        for _ in 0..<8 {
            let viewport = window.frame
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : viewport.minY
            let bottom = viewport.maxY - 120
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            if exists && element.isHittable && frame.minY >= top && frame.maxY <= bottom { break }
            let down = exists ? frame.minY < top : towardTop
            let x = exists ? min(max((frame.midX - viewport.minX) / viewport.width, 0.1), 0.9) : 0.5
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: down ? 0.35 : 0.65))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: down ? 0.65 : 0.35))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    func assertNotificationsWidth(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = app.windows.firstMatch.frame
        XCTAssertGreaterThan(element.frame.width, 0)
        XCTAssertGreaterThanOrEqual(element.frame.minX, viewport.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, viewport.maxX)
    }

    @MainActor
    func captureNotifications(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
