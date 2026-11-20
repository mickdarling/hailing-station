import XCTest

extension AdvancedSettingsUITests {
    @MainActor
    func launchShell(_ app: XCUIApplication, extra: [String] = []) {
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
        app.launchArguments = extra
        app.launch()
        XCTAssertTrue(section("settings", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func openAdvanced(_ app: XCUIApplication) {
        tapSection("settings", in: app)
        let entry = app.buttons["settings.advanced.entry"]
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Advanced and diagnostics"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["station.connection"].firstMatch.exists)
    }

    @MainActor
    func visitTool(_ identifier: String, title: String, in app: XCUIApplication) {
        let link = app.buttons[identifier]
        reveal(link, in: app)
        link.tap()
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let back = bar.buttons["Advanced and diagnostics"]
        waitUntilHittable(back)
        back.tap()
        XCTAssertTrue(app.navigationBars["Advanced and diagnostics"].waitForExistence(timeout: 5))
    }

    @MainActor
    func section(_ name: String, in app: XCUIApplication) -> XCUIElement {
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
    func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
