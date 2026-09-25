import XCTest

/// Drives Apple's TestFlight UI without building or reinstalling Hailing Station.
/// Pass HAIL_EXPECTED_TESTFLIGHT_VERSION=<version> to xcodebuild.
final class InstalledTestFlightUpdateTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            throw XCTSkip("TestFlight updates require a paired physical device.")
        }
    }

    @MainActor
    func testInstallExpectedHailingStationUpdate() throws {
        guard let expectedVersion = Bundle(for: Self.self)
            .object(forInfoDictionaryKey: "HailExpectedTestFlightVersion") as? String,
            !expectedVersion.isEmpty else {
            throw XCTSkip("Provide HailExpectedTestFlightVersion before allowing an update.")
        }

        let testFlight = XCUIApplication(bundleIdentifier: "com.apple.TestFlight")
        testFlight.launch()

        let appName = testFlight.staticTexts["Hailing Station"].firstMatch
        XCTAssertTrue(appName.waitForExistence(timeout: 30),
                      "Hailing Station was not listed in TestFlight on this device.")
        appName.tap()

        XCTAssertTrue(testFlight.staticTexts[expectedVersion].firstMatch
            .waitForExistence(timeout: 30),
            "TestFlight does not show the expected release version; no update was started.")
        let update = testFlight.buttons["Update"].firstMatch
        if update.waitForExistence(timeout: 15) {
            update.tap()
        }

        XCTAssertTrue(testFlight.buttons["Open"].firstMatch.waitForExistence(timeout: 180),
                      "The expected TestFlight release is neither installed nor finished updating.")
    }
}
