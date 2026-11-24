import XCTest

/// Reads settings and visits the existing tool without touching any audio, playback or preference action.
final class VoicesSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Voices settings checks run only on an owned, unconfigured simulator.")
        }
    }

    @MainActor
    func testExistingSettingsAndToolRemainReadOnlyWhileVisiting() {
        let app = XCUIApplication()
        launchShell(app)
        openVoices(app)
        let before = readSettings(in: app)
        XCTAssertTrue(before[0].contains("seconds") && before[1].contains("seconds"))
        XCTAssertTrue(before[2].contains("dBFS"))
        let unavailable = app.staticTexts["settings.voices.assignments-unavailable"]
        reveal(unavailable, in: app)
        XCTAssertTrue(unavailable.label.contains("cannot read or edit"))
        capture(app, named: "voices-local-settings-no-host-map")
        let tools = app.buttons["settings.voices.turn-taking"]
        reveal(tools, in: app)
        tools.tap()
        XCTAssertTrue(app.navigationBars["Turn-taking"].waitForExistence(timeout: 5))
        back(from: "Turn-taking", to: "Voices and replies", in: app)
        XCTAssertEqual(readSettings(in: app), before)
        back(from: "Voices and replies", to: "Settings", in: app)
        let original = app.buttons["Turn-taking"]
        reveal(original, in: app)
        original.tap()
        XCTAssertTrue(app.navigationBars["Turn-taking"].waitForExistence(timeout: 5))
        back(from: "Turn-taking", to: "Settings", in: app)
    }

    @MainActor
    func testLargestDynamicTypeAndLandscapeKeepValuesAndNavigationReachable() {
        let app = XCUIApplication()
        launchShell(app, extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openVoices(app)
        XCTAssertEqual(readSettings(in: app).count, 3)
        capture(app, named: "voices-largest-type")
        XCUIDevice.shared.orientation = .landscapeLeft
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if frame.width > frame.height { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        let unavailable = app.staticTexts["settings.voices.assignments-unavailable"]
        reveal(unavailable, in: app)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(unavailable.frame.width, 0)
        XCTAssertGreaterThanOrEqual(unavailable.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(unavailable.frame.maxX, window.maxX)
        waitUntilHittable(app.navigationBars["Voices and replies"].buttons["Settings"])
        capture(app, named: "voices-largest-type-landscape")
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
    }

    @MainActor
    private func openVoices(_ app: XCUIApplication) {
        let settings = UIDevice.current.userInterfaceIdiom == .pad
            ? app.staticTexts["station.section.settings"].firstMatch : app.buttons["station.tab.settings"].firstMatch
        waitUntilHittable(settings)
        settings.tap()
        let entry = app.buttons["settings.voices.entry"]
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Voices and replies"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["station.connection"].firstMatch.exists)
    }

    @MainActor
    private func readSettings(in app: XCUIApplication) -> [String] {
        ["pause", "onset", "threshold"].map { name in
            let row = app.descendants(matching: .any)["settings.voices.\(name)"].firstMatch
            reveal(row, in: app, towardTop: name == "pause")
            XCTAssertFalse(row.label.isEmpty)
            return row.label
        }
    }

    @MainActor
    private func back(from title: String, to destination: String, in app: XCUIApplication) {
        let button = app.navigationBars[title].buttons[destination]
        waitUntilHittable(button)
        button.tap()
        XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5))
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
