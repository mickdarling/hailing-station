import XCTest

final class DestinationSetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyStationLinksDirectlyToMacSetup() throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("The empty-state setup check runs in a fresh simulator.")
        }
        let app = XCUIApplication()
        app.launchArguments.append("-reset-station-state")
        app.launch()

        let setup = app.buttons["station.setup-mac"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        setup.tap()
        XCTAssertTrue(app.navigationBars["Mac Setup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["How it works"].exists)
    }

    @MainActor
    func testSelectedDestinationNamesMacAndTerminalSession() throws {
        guard let targetLabel = ProcessInfo.processInfo.environment["HAIL_UI_TARGET_LABEL"] else {
            throw XCTSkip("Set the sanitized physical host and target UI test environment.")
        }
        let app = XCUIApplication()
        app.launch()

        let destination = app.buttons["station.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        let destinationNames = targetLabel.components(separatedBy: " · ")
        XCTAssertEqual(destinationNames.count, 2)
        let selected = NSPredicate(
            format: "value CONTAINS %@ AND value CONTAINS %@",
            destinationNames[0], destinationNames[1]
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: selected, object: destination)],
                timeout: 30
            ),
            .completed
        )
        XCTAssertEqual(destination.label, "Destination")
        let accessibleValue = try XCTUnwrap(destination.value as? String)
        XCTAssertTrue(accessibleValue.contains("Mac \(destinationNames[0])"))
        XCTAssertTrue(accessibleValue.contains(destinationNames[1]))
    }
}
