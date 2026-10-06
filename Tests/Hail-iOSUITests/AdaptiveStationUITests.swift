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

    /// #288: on an iPad the station fits one screen, so its controls are hittable without scrolling either way up.
    @MainActor
    func testIPadStationFitsOneScreenInBothOrientations() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout only.") }
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 10))
            for identifier in [
                "station.connection", "station.destination", "station.microphone", "station.output",
                "station.mac-setup-tool", "station.diagnostics-toggle", "station.build-info"
            ] {
                let element = app.descendants(matching: .any)[identifier].firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier) missing")
                XCTAssertTrue(element.isHittable, "\(identifier) needs scrolling in \(orientation.rawValue)")
            }
        }
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
