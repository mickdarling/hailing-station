import XCTest

/// The "Diagnostics logging" switch (#234): off after a reset, explains itself, and says when no Mac collects.
final class DiagnosticsLoggingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Diagnostics toggle checks run in the simulator without changing installed device builds.")
        }
    }

    @MainActor
    func testTheToggleStartsOffAndSaysWhenNoMacIsCollecting() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-reset-station-state")
        app.launch()
        let toggle = app.switches["station.diagnostics-toggle"]
        for _ in 0..<4 where !toggle.exists { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        let status = app.staticTexts["station.diagnostics-status"]
        XCTAssertTrue(status.label.hasPrefix("Off. Nothing is recorded or sent."))
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(status.label.contains("no connected Mac is collecting"))
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }
}
