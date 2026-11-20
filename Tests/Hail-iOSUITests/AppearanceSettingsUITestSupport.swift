import XCTest

/// Helpers launch only the isolated Debug fixtures, never the station or its audio and host resources.
extension AppearanceSettingsUITests {
    @MainActor
    func launch(reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appearance-preview"]
            + (reset ? ["-reset-appearance-preview"] : []) + extra
        app.launch()
        XCTAssertTrue(element("appearance.settings", in: app).waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func launchEntryPreview() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appearance-preview", "-reset-appearance-preview", "-appearance-entry-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["station.settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("station.connection", in: app).exists)
        return app
    }

    @MainActor
    func assertDoneVisible(in app: XCUIApplication) {
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable, "Done must remain reachable without scrolling the sheet.")
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(done.frame), "Done must fit inside the app viewport.")
    }

    @MainActor
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func assertValue(_ expected: String, in app: XCUIApplication) {
        let value = app.descendants(matching: .any).matching(identifier: "appearance.text-size.value")
            .matching(NSPredicate(format: "value == %@", expected)).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5), "Expected the conversation size value \(expected).")
    }

    @MainActor
    func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<5 {
            guard !element.isHittable else { return }
            if element.frame.maxY < app.frame.midY { scroll.swipeDown() } else { scroll.swipeUp() }
        }
    }

    @MainActor
    func attach(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func waitForOrientation(landscape: Bool, in app: XCUIApplication) {
        let settled = XCTestExpectation(description: landscape ? "Landscape viewport" : "Portrait viewport")
        @MainActor func observe(remaining: Int) {
            let frame = app.frame
            if frame.width > 0, frame.height > 0, (frame.width > frame.height) == landscape {
                settled.fulfill()
            } else if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { observe(remaining: remaining - 1) }
            }
        }
        observe(remaining: 50)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 6), .completed,
                       "The simulator must finish rotating before sheet visibility is checked.")
    }
}
