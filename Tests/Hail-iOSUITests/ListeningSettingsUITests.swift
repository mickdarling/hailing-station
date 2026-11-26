import XCTest

/// Read-only visits and navigation on an unconfigured simulator; no listening, preference or permission action.
final class ListeningSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Listening settings checks run only on an owned, unconfigured simulator.")
        }
    }

    @MainActor
    func testUnreportedAmbientStateAndSavedPreferenceSurviveNavigation() {
        let app = XCUIApplication()
        launchShell(app)
        openListening(app)
        let request = element("settings.listening.request", in: app)
        reveal(request, in: app, towardTop: true)
        XCTAssertTrue(request.label.contains("Not reported"))
        let activity = element("settings.listening.activity", in: app)
        reveal(activity, in: app)
        XCTAssertTrue(activity.label.contains("Not reported"))
        let mask = app.switches["settings.listening.mask-preference"]
        reveal(mask, in: app)
        let saved = mask.value as? String
        XCTAssertTrue(["0", "1"].contains(saved ?? ""))
        capture(app, named: "listening-unreported-saved-preference")
        let manage = app.buttons["settings.listening.manage"]
        reveal(manage, in: app, towardTop: true)
        manage.tap()
        XCTAssertTrue(element("station.connection", in: app).waitForExistence(timeout: 5))
        openListening(app)
        reveal(mask, in: app)
        XCTAssertEqual(mask.value as? String, saved)
        let back = app.navigationBars["Listening and attention"].buttons["Settings"]
        waitUntilHittable(back)
        back.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLargestDynamicTypeAndLandscapeKeepStatusAndNavigationReachable() {
        let app = XCUIApplication()
        launchShell(app, extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openListening(app)
        let activity = element("settings.listening.activity", in: app)
        reveal(activity, in: app, towardTop: true)
        XCTAssertTrue(activity.label.contains("Not reported"))
        capture(app, named: "listening-largest-type")
        XCUIDevice.shared.orientation = .landscapeLeft
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if frame.width > frame.height { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        let unavailable = app.staticTexts["settings.listening.attention-unavailable"]
        reveal(unavailable, in: app)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(unavailable.frame.width, 0)
        XCTAssertGreaterThanOrEqual(unavailable.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(unavailable.frame.maxX, window.maxX)
        waitUntilHittable(app.navigationBars["Listening and attention"].buttons["Settings"])
        capture(app, named: "listening-largest-type-landscape")
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
        app.launchArguments = ClassicStationFixture.resetArguments
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
    private func openListening(_ app: XCUIApplication) {
        let settings = UIDevice.current.userInterfaceIdiom == .pad
            ? app.staticTexts["station.section.settings"].firstMatch : app.buttons["station.tab.settings"].firstMatch
        waitUntilHittable(settings)
        settings.tap()
        let entry = app.buttons["settings.listening.entry"]
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Listening and attention"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("station.connection", in: app).exists)
    }

    @MainActor
    private func waitUntilHittable(_ item: XCUIElement) {
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: item)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 5), .completed)
        XCTAssertTrue(item.isHittable)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
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
