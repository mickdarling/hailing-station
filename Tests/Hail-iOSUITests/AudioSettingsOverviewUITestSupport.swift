import XCTest

extension AudioSettingsOverviewUITests {
    @MainActor
    func launchShell(_ app: XCUIApplication, extraArguments: [String] = []) {
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
        XCTAssertFalse(element("settings.audio.overview", in: app).exists, "The classic station hides Audio settings")
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
    func openOverview(_ app: XCUIApplication) {
        tapSection("settings", in: app)
        let audio = app.buttons["station.settings.audio"]
        waitUntilHittable(audio)
        audio.tap()
        XCTAssertTrue(app.navigationBars["Audio"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings.audio.overview", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("station.connection", in: app).exists, "The mounted Station stays hidden")
        XCTAssertFalse(app.buttons["Activate"].exists, "Session actions require opening the separate tool")
    }

    @MainActor
    func assertInactiveOverview(_ app: XCUIApplication) {
        let input = element("settings.audio.input", in: app)
        reveal(input, in: app, towardTop: true)
        XCTAssertTrue(input.label.contains("Audio inactive"))
        let output = element("settings.audio.output", in: app)
        reveal(output, in: app)
        XCTAssertTrue(output.label.contains("System output"))
        XCTAssertFalse(app.buttons["Activate"].exists)
    }

    @MainActor
    func section(_ name: String, in app: XCUIApplication) -> XCUIElement {
        // The sidebar icon shares its identifier with the title but is not hittable.
        UIDevice.current.userInterfaceIdiom == .pad
            ? app.staticTexts["station.section.\(name)"].firstMatch
            : app.buttons["station.tab.\(name)"].firstMatch
    }

    @MainActor
    func tapSection(_ name: String, in app: XCUIApplication) {
        let item = section(name, in: app)
        waitUntilHittable(item)
        item.tap()
    }

    @MainActor
    func waitUntilHittable(_ item: XCUIElement) {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: item)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 5), .completed)
        XCTAssertTrue(item.isHittable)
    }

    @MainActor
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        let window = app.windows.firstMatch
        for _ in 0..<8 {
            let viewport = window.frame
            let top = app.navigationBars.firstMatch.exists
                ? app.navigationBars.firstMatch.frame.maxY : viewport.minY
            let bottom = viewport.maxY - 120
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            if exists && element.isHittable && frame.minY >= top && frame.maxY <= bottom { break }
            let moveDown = exists ? frame.minY < top : towardTop
            let x = exists
                ? min(max((frame.midX - viewport.minX) / viewport.width, 0.1), 0.9) : 0.5
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: moveDown ? 0.35 : 0.65))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: moveDown ? 0.65 : 0.35))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    func assertFitsWidth(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = app.windows.firstMatch.frame
        XCTAssertGreaterThan(element.frame.width, 0)
        XCTAssertGreaterThanOrEqual(element.frame.minX, viewport.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, viewport.maxX)
    }

    @MainActor
    func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
