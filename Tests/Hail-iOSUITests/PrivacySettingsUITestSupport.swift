import XCTest

extension PrivacySettingsUITests {
    @MainActor
    func privacyOverheardReading(_ app: XCUIApplication) throws -> [String] {
        let show = app.switches["settings.privacy.overheard-show"]
        revealPrivacyElement(show, in: app)
        let preference = try XCTUnwrap(show.value as? String)
        let scope = privacyElement("settings.privacy.overheard-requested", in: app)
        revealPrivacyElement(scope, in: app)
        XCTAssertFalse(scope.label.isEmpty)
        return [preference, scope.label]
    }

    @MainActor
    func closePrivacyToSettings(_ app: XCUIApplication) {
        let back = app.navigationBars["Privacy"].buttons["Settings"]
        waitForPrivacyElement(back)
        back.tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForNonExistence(timeout: 5))
        waitForPrivacyElement(app.buttons["station.settings.privacy"])
    }

    @MainActor
    func launchPrivacyShell(_ app: XCUIApplication, arguments: [String] = []) {
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
        XCTAssertFalse(privacyElement("settings.privacy.page", in: app).exists)
        let labs = app.buttons["Labs"]
        revealPrivacyElement(labs, in: app)
        labs.tap()
        if !app.navigationBars["Labs"].waitForExistence(timeout: 3), labs.isHittable { labs.tap() }
        XCTAssertTrue(app.navigationBars["Labs"].waitForExistence(timeout: 5))
        let toggle = app.switches["station.redesign.shell"]
        revealPrivacyElement(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.terminate()
        app.launchArguments = arguments
        app.launch()
    }

    @MainActor
    func openPrivacy(_ app: XCUIApplication) {
        tapPrivacySection("settings", in: app)
        let privacy = app.buttons["station.settings.privacy"]
        waitForPrivacyElement(privacy)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 5))
        XCTAssertTrue(privacyElement("settings.privacy.page", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(privacyElement("station.connection", in: app).exists)
    }

    @MainActor
    func tapPrivacySection(_ name: String, in app: XCUIApplication) {
        let item = UIDevice.current.userInterfaceIdiom == .pad
            ? app.staticTexts["station.section.\(name)"].firstMatch : app.buttons["station.tab.\(name)"].firstMatch
        waitForPrivacyElement(item)
        item.tap()
    }

    @MainActor
    func waitForPrivacyElement(_ item: XCUIElement) {
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: item)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 5), .completed)
        XCTAssertTrue(item.isHittable)
    }

    @MainActor
    func privacyElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    func revealPrivacyElement(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        for _ in 0..<8 {
            let viewport = window.frame
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : viewport.minY
            let bottom = viewport.maxY - 120
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            if exists && element.isHittable && frame.minY >= top && frame.maxY <= bottom { break }
            let down = exists && frame.minY < top
            let x = exists ? min(max((frame.midX - viewport.minX) / viewport.width, 0.1), 0.9) : 0.5
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: down ? 0.35 : 0.65))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: down ? 0.65 : 0.35))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    func assertPrivacyWidth(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = app.windows.firstMatch.frame
        XCTAssertGreaterThan(element.frame.width, 0)
        XCTAssertGreaterThanOrEqual(element.frame.minX, viewport.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, viewport.maxX)
    }

    @MainActor
    func capturePrivacy(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
