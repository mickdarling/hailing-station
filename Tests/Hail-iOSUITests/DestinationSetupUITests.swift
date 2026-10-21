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

    /// #385: with a Mac configured but unreachable, "Check Mac connection" shows that it is checking, then a result.
    @MainActor
    func testCheckMacConnectionShowsProgressThenAResult() throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("The connection check runs in a fresh simulator.")
        }
        let app = XCUIApplication()
        app.launchArguments.append("-reset-station-state")
        app.launch()

        let setup = app.buttons["station.setup-mac"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        setup.tap()
        XCTAssertTrue(app.navigationBars["Mac Setup"].waitForExistence(timeout: 5))
        let name = app.textFields["Name"]
        name.tap()
        name.typeText("Unreachable Mac")
        let url = app.textFields["WebSocket URL"]
        url.tap()
        url.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "ws://127.0.0.1:9")
        app.buttons["Add Mac"].tap()
        app.buttons["Connect"].firstMatch.tap()
        app.navigationBars["Mac Setup"].buttons.element(boundBy: 0).tap()

        let check = app.buttons["station.check-connection"]
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        check.tap()
        let result = app.staticTexts["station.connection-check-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        let finished = NSPredicate(format: "NOT (label CONTAINS %@)", "Checking")
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: result)], timeout: 20),
            .completed
        )
        // A named problem, never success, for a Mac at an unreachable address. A simulator with a remembered
        // destination checks that Mac instead, so the name is not asserted.
        let problems = ["did not answer", "could not connect"]
        XCTAssertTrue(problems.contains { result.label.contains($0) }, result.label)
        XCTAssertTrue(app.buttons["station.setup-mac"].exists)

        // Leaving for Mac Setup mid-check and coming back leaves the check idle, never spinning (#385 review).
        check.tap()
        app.buttons["station.setup-mac"].tap()
        XCTAssertTrue(app.navigationBars["Mac Setup"].waitForExistence(timeout: 5))
        app.navigationBars["Mac Setup"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        XCTAssertTrue(check.isEnabled)
        XCTAssertFalse(app.staticTexts["station.connection-check-result"].exists)
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
        let selected = destinationValuePredicate(for: targetLabel)
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

func destinationValuePredicate(for label: String) -> NSPredicate {
    let names = label.components(separatedBy: " · ")
    guard names.count == 2 else { return NSPredicate(format: "value == %@", label) }
    return NSPredicate(
        format: "value CONTAINS %@ AND value CONTAINS %@",
        names[0], names[1]
    )
}
