import XCTest

/// Exercise the existing Settings action against one finished message in the classic station.
extension AppearanceStationIntegrationUITests {
    @MainActor
    func testChangingAaResizesTheSameClassicParagraphWithoutRelaunch() {
        let app = ClassicStationFixture.application(reset: true)
        app.launchArguments += ["-seed-conversation", "3", "-overheard.show", "NO"]
        app.launch()
        let reply = "Turn 3. The invented weather stays mild and the invented garden needs watering again."
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label == %@", reply)).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
        reveal(paragraph, scrollingUp: false, in: app.windows.firstMatch)
        let before = paragraph.frame.height
        XCTAssertGreaterThan(before, 0)
        let initial = XCTAttachment(screenshot: app.screenshot())
        openSizeSettings(in: app)
        let grow = app.buttons["appearance.text-size.larger"].isEnabled
        let forward = grow ? "larger" : "smaller"
        let undo = grow ? "smaller" : "larger"
        app.buttons["appearance.text-size." + forward].tap()
        closeSettings(in: app)
        reveal(paragraph, scrollingUp: false, in: app.windows.firstMatch)

        let after = paragraph.frame.height
        XCTAssertGreaterThan(after, 0)
        XCTAssertGreaterThan(grow ? after : before, grow ? before : after)
        initial.name = "station-classic-text-" + undo
        initial.lifetime = .keepAlways
        add(initial)
        let changed = XCTAttachment(screenshot: app.screenshot())
        changed.name = "station-classic-text-" + forward
        changed.lifetime = .keepAlways
        add(changed)

        openSizeSettings(in: app)
        let notice = app.staticTexts["Preview preference. Live conversation text sizing is not available yet."]
        XCTAssertFalse(notice.exists)
        app.buttons["appearance.text-size." + undo].tap()
        closeSettings(in: app)
    }

    @MainActor
    private func openSizeSettings(in app: XCUIApplication) {
        let settings = app.buttons["station.settings"]
        let station = app.scrollViews.containing(.button, identifier: "station.settings").firstMatch
        // A one-screen iPad nests Settings in its own scrollable secondary column.
        let column = station.scrollViews.containing(.button, identifier: "station.settings").firstMatch
        reveal(settings, scrollingUp: true, in: column.exists ? column : station)
        settings.tap()
        XCTAssertTrue(app.buttons["appearance.text-size.larger"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func closeSettings(in app: XCUIApplication) {
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["appearance.text-size.larger"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, scrollingUp: Bool, in container: XCUIElement) {
        // The edge of the selected container stays clear of nested controls.
        let top = container.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.24))
        let bottom = container.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.82))
        for _ in 0..<8 where !element.isHittable {
            (scrollingUp ? bottom : top).press(forDuration: 0.05, thenDragTo: scrollingUp ? top : bottom)
        }
        XCTAssertTrue(element.isHittable)
    }
}
