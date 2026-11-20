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
    func testTheActualSettingsEntryPresentsAndDismissesTheIsolatedSheet() {
        let app = launchEntryPreview()
        XCTAssertTrue(element("appearance.example-tools", in: app).exists)
        XCTAssertFalse(element("appearance.settings", in: app).exists)
        app.buttons["station.settings"].tap()

        assertValue("17 points, default", in: app)
        XCTAssertTrue(element("appearance.conversation-preview", in: app).exists)
        assertDoneVisible(in: app)
        app.buttons["Done"].tap()

        XCTAssertTrue(element("appearance.settings", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["station.settings"].isHittable)
        XCTAssertTrue(element("appearance.example-tools", in: app).exists)
    }

    @MainActor
    func testTheActualSheetStaysOpenAcrossRotationAndFitsCompactLandscape() {
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = launchEntryPreview()
        app.buttons["station.settings"].tap()
        assertValue("17 points, default", in: app)
        app.buttons["appearance.text-size.larger"].tap()
        assertValue("19 points", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(landscape: true, in: app)
        XCTAssertTrue(element("appearance.settings", in: app).exists, "Rotation must keep the actual sheet open.")
        assertValue("19 points", in: app)
        assertDoneVisible(in: app)
        attach(app, named: "appearance-entry-sheet-landscape")

        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(landscape: false, in: app)
        XCTAssertTrue(element("appearance.settings", in: app).exists)
        assertValue("19 points", in: app)
        assertDoneVisible(in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(element("appearance.settings", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["station.settings"].isHittable)
        XCTAssertTrue(element("appearance.example-tools", in: app).exists)
    }

    @MainActor
    func testTheWindowOwnedSheetSurvivesReplacingItsEntireSettingsEntry() {
        let app = launchEntryPreview()
        app.buttons["station.settings"].tap()
        assertValue("17 points, default", in: app)
        app.buttons["appearance.text-size.larger"].tap()
        assertValue("19 points", in: app)

        let changeLayout = app.buttons["appearance.example-layout"]
        XCTAssertTrue(changeLayout.waitForExistence(timeout: 5))
        for _ in 0..<2 {
            XCTAssertTrue(changeLayout.isHittable)
            changeLayout.tap()
            XCTAssertFalse(element("appearance.settings", in: app).waitForNonExistence(timeout: 1),
                           "Replacing the entire entry's layout branch must not dismiss its window-owned sheet.")
            assertValue("19 points", in: app)
            assertDoneVisible(in: app)
        }
        app.buttons["Done"].tap()
        XCTAssertTrue(element("appearance.settings", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["station.settings"].isHittable)
        XCTAssertTrue(element("appearance.example-tools", in: app).exists)
    }
}
