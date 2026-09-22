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
        app.launch()

        let setup = app.buttons["station.setup-mac"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        setup.tap()
        XCTAssertTrue(app.navigationBars["Mac Setup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["How it works"].exists)
    }

    @MainActor
    func testSelectedDestinationNamesMacAndTerminalSession() throws {
        guard let hostName = ProcessInfo.processInfo.environment["HAIL_UI_HOST_NAME"],
              let targetLabel = ProcessInfo.processInfo.environment["HAIL_UI_TARGET_LABEL"] else {
            throw XCTSkip("Set the sanitized physical host and target UI test environment.")
        }
        let app = XCUIApplication()
        app.launch()

        let destination = app.buttons["station.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        let selected = NSPredicate(format: "value == %@", targetLabel)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: selected, object: destination)],
                timeout: 30
            ),
            .completed
        )
        XCTAssertTrue(app.staticTexts["Mac · \(hostName)"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Terminal · '")).firstMatch.exists)
    }
}
