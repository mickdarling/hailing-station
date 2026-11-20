import XCTest

/// The Debug-only preview entry point never constructs the station or any host, capture or playback resources.
final class AppearanceSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Appearance preview checks use simulators and isolated preview preferences only.")
        }
    }

    @MainActor
    func testTheSyntheticInitialScreenCanBeCapturedOnIPhoneAndIPad() {
        let app = launch()
        assertValue("17 points, default", in: app)
        XCTAssertTrue(element("appearance.conversation-preview", in: app).exists)
        XCTAssertFalse(element("station.connection", in: app).exists)
        attach(app, named: "appearance-settings-initial")
    }

    @MainActor
    func testLargerAndResetPersistAcrossPreviewRelaunches() {
        var app = launch()
        assertValue("17 points, default", in: app)
        app.buttons["appearance.text-size.larger"].tap()
        assertValue("19 points", in: app)
        app.terminate()

        app = launch(reset: false)
        assertValue("19 points", in: app)
        let reset = app.buttons["appearance.text-size.reset"]
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        assertValue("17 points, default", in: app)
        app.terminate()

        app = launch(reset: false)
        assertValue("17 points, default", in: app)
        XCTAssertFalse(app.buttons["appearance.text-size.reset"].isEnabled)
    }

    @MainActor
    func testActionsRemainReachableAtTheLargestAccessibilityTextSize() {
        let app = launch(extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let larger = app.buttons["appearance.text-size.larger"]
        reveal(larger, in: app)
        larger.tap()
        assertValue("19 points", in: app)
        for name in ["smaller", "larger", "reset"] {
            let action = app.buttons["appearance.text-size.\(name)"]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            reveal(action, in: app)
            XCTAssertTrue(action.isHittable, "\(name) must remain reachable by scrolling the settings screen.")
        }
        attach(app, named: "appearance-settings-accessibility-xxxl")
    }

    @MainActor
    private func launch(reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appearance-preview"]
            + (reset ? ["-reset-appearance-preview"] : []) + extra
        app.launch()
        XCTAssertTrue(element("appearance.settings", in: app).waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func assertValue(_ expected: String, in app: XCUIApplication) {
        let value = app.descendants(matching: .any).matching(identifier: "appearance.text-size.value")
            .matching(NSPredicate(format: "value == %@", expected)).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5), "Expected the conversation size value \(expected).")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<5 {
            guard !element.isHittable else { return }
            if element.frame.maxY < app.frame.midY { scroll.swipeDown() } else { scroll.swipeUp() }
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
