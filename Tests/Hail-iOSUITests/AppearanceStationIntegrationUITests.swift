import XCTest

/// UI-only navigation on a fresh, unconfigured simulator: no capture, playback or audio-route actions.
final class AppearanceStationIntegrationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Station entry coverage requires an unconfigured simulator.")
        }
    }

    @MainActor
    func testSettingsOpensAndClosesFromTheRealStation() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset-station-state"]
        app.launch()
        let settings = app.buttons["station.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            guard !settings.isHittable else { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        settings.tap()
        let screen = app.descendants(matching: .any).matching(identifier: "appearance.settings").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        let value = app.descendants(matching: .any).matching(identifier: "appearance.text-size.value").firstMatch
        XCTAssertTrue(value.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "appearance-real-station-settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "station.tools").firstMatch.exists)
    }
}
