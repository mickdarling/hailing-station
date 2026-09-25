import XCTest

/// Drives Apple's TestFlight UI without building or reinstalling Hailing Station.
/// Pass HAIL_EXPECTED_TESTFLIGHT_VERSION and HAIL_EXPECTED_TESTFLIGHT_BUILD to xcodebuild.
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
            !expectedVersion.isEmpty,
            let expectedBuild = Bundle(for: Self.self)
                .object(forInfoDictionaryKey: "HailExpectedTestFlightBuild") as? String,
            !expectedBuild.isEmpty else {
            throw XCTSkip("Provide the expected TestFlight version and build before allowing an update.")
        }

        let testFlight = XCUIApplication(bundleIdentifier: "com.apple.TestFlight")
        testFlight.launch()

        let appName = testFlight.staticTexts["Hailing Station"].firstMatch
        XCTAssertTrue(appName.waitForExistence(timeout: 30),
                      "Hailing Station was not listed in TestFlight on this device.")
        appName.tap()

        let release = testFlight.staticTexts["TestFlight.appDetails.shortVersion"]
        XCTAssertTrue(release.waitForExistence(timeout: 30),
                      "TestFlight did not expose the current release; no update was started.")
        let numericFields = release.label.split(whereSeparator: { !$0.isNumber }).map(String.init)
        let expectedFields = expectedVersion.split(separator: ".").map(String.init) + [expectedBuild]
        XCTAssertEqual(numericFields, expectedFields,
                      "TestFlight does not show the expected release version and build; no update was started.")
        let offerButton = NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
                                      "TestFlight.offerButton.", "TestFlight.offerButton.open")
        let update = testFlight.buttons.matching(offerButton).firstMatch
        if update.waitForExistence(timeout: 15) {
            update.tap()
        }

        XCTAssertTrue(testFlight.buttons["TestFlight.offerButton.open"].waitForExistence(timeout: 180),
                      "The expected TestFlight release is neither installed nor finished updating.")
    }
}
