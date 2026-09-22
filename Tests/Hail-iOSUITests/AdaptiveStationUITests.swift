import XCTest

final class AdaptiveStationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == nil {
            throw XCTSkip("Adaptive layout smoke coverage runs in the simulator matrix.")
        }
    }

    @MainActor
    func testStationChromeRemainsAvailableAcrossCompactRotation() {
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
        }
        let app = XCUIApplication()
        app.launch()

        assertStationChrome(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertStationChrome(in: app)
    }

    @MainActor
    func testMicrophoneMenuCanBootstrapAFreshSession() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 10))

        let microphone = app.buttons["station.microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 10))
        XCTAssertTrue(microphone.isEnabled)
        microphone.tap()
        XCTAssertTrue(app.buttons["Automatic"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertStationChrome(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["station.connection"].exists)
        XCTAssertTrue(app.buttons["station.destination"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["station.audio-route"].exists)
        XCTAssertTrue(app.buttons["station.microphone"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["station.output"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["station.tools"].exists)
    }
}
