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

    @MainActor
    private func launchShell(_ app: XCUIApplication, extra: [String] = []) {
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
    private func openAdvanced(_ app: XCUIApplication) {
        tapSection("settings", in: app)
        let entry = app.buttons["settings.advanced.entry"]
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Advanced and diagnostics"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["station.connection"].firstMatch.exists)
    }

    @MainActor
    private func visitTool(_ identifier: String, title: String, in app: XCUIApplication) {
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
    private func section(_ name: String, in app: XCUIApplication) -> XCUIElement {
        UIDevice.current.userInterfaceIdiom == .pad
            ? app.staticTexts["station.section.\(name)"].firstMatch
            : app.buttons["station.tab.\(name)"].firstMatch
    }

    @MainActor
    private func tapSection(_ name: String, in app: XCUIApplication) {
        let item = section(name, in: app)
        waitUntilHittable(item)
        item.tap()
    }

    @MainActor
    private func waitUntilHittable(_ item: XCUIElement) {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: item)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 5), .completed)
        XCTAssertTrue(item.isHittable)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
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
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
