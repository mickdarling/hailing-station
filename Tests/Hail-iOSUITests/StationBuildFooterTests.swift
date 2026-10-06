import XCTest

final class StationBuildFooterTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("Footer layout checks run in the simulator without changing installed device builds.")
        }
    }

    @MainActor
    func testFooterRemainsVisibleAcrossStationScrollAndRotation() throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments.append("-reset-station-state")
        app.launch()
        let label = try assertFooter(in: app)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertEqual(try assertFooter(in: app), label)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(try assertFooter(in: app), label)
    }

    @MainActor
    func testFooterSupportsLargestDynamicTypeWhileScrolling() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-reset-station-state", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        let label = try assertFooter(in: app)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertEqual(try assertFooter(in: app), label)
    }

    @MainActor
    func testFooterRemainsAvailableWithAConfiguredOfflineMac() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-reset-station-state")
        app.launch()
        let label = try assertFooter(in: app)
        XCTAssertTrue(app.staticTexts["Connect Haili to a Mac"].exists)
        app.scrollViews.firstMatch.swipeUp()
        let setup = app.buttons["station.mac-setup-tool"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        setup.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Fixture Mac")
        // Saving a fixture exercises configured state without connecting to any host.
        app.buttons["Add Mac"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Mac"].waitForExistence(timeout: 5))
        app.navigationBars["Mac Setup"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Mac is offline"].waitForExistence(timeout: 5))
        XCTAssertEqual(try assertFooter(in: app), label)
    }

    @MainActor
    @discardableResult
    private func assertFooter(in app: XCUIApplication) throws -> String {
        let footer = app.staticTexts["station.build-info"]
        XCTAssertTrue(footer.waitForExistence(timeout: 10))
        XCTAssertTrue(footer.isHittable, "The footer must remain visible without scrolling to the end of the Station.")
        XCTAssertNotNil(footer.label.range(of: #"^Version [0-9]+(?:\.[0-9]+)* · Build [0-9]+$"#,
                                         options: .regularExpression))
        // App and UI-test bundle inherit the same release identifiers from project.yml.
        let metadata = Bundle(for: Self.self)
        let version = try XCTUnwrap(metadata.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = try XCTUnwrap(metadata.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertEqual(footer.label, "Version \(version) · Build \(build)")
        XCTAssertGreaterThan(footer.frame.width, 0)
        XCTAssertGreaterThan(footer.frame.height, 0)
        XCTAssertGreaterThanOrEqual(footer.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(footer.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(footer.frame.maxY, app.frame.maxY)
        return footer.label
    }
}
