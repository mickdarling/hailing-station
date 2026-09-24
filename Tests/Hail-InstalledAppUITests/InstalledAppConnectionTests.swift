import XCTest

/// Runs against the already-installed App Store/TestFlight binary. This target intentionally
/// has no Hail-iOS build dependency, so an Xcode test run cannot replace the beta app.
final class InstalledAppConnectionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            throw XCTSkip("This check requires a paired physical device.")
        }
    }

    @MainActor
    func testConnectsAndSelectsAllowedTarget() throws {
        let app = XCUIApplication(bundleIdentifier: "com.mickdarling.Hail-iOS")
        app.launch()
        // A restored Mac can start connecting before Mac Setup opens, prompting on first launch.
        allowLocalNetworkIfRequested()
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 20),
                      "The installed Hailing Station app did not open.")
        ensureSavedMacReady(in: app)

        let destination = app.buttons["station.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 30), "Destination control is missing.")
        let choose = app.buttons["station.choose-destination"]
        if choose.exists { choose.tap() } else { destination.tap() }
        XCTAssertTrue(app.navigationBars["Choose a destination"].waitForExistence(timeout: 10),
                      "Destination browser did not open.")
        let targets = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", " · "))
        XCTAssertTrue(targets.firstMatch.waitForExistence(timeout: 30), "No allowed target arrived.")
        let liveTargets = targets.allElementsBoundByIndex.filter(\.isEnabled)
        XCTAssertEqual(liveTargets.count, 1, "Expected exactly one live allowed target.")
        liveTargets[0].tap()
        let selected = NSPredicate(format: "value BEGINSWITH 'Mac ' AND value CONTAINS 'Terminal '")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected,
                                                                     object: destination)],
                                  timeout: 10), .completed,
                       "The allowed target did not remain selected.")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func ensureSavedMacReady(in app: XCUIApplication) {
        let setup = app.buttons["station.mac-setup-tool"]
        XCTAssertTrue(setup.waitForExistence(timeout: 20), "Mac Setup is unavailable.")
        setup.tap()
        XCTAssertTrue(app.navigationBars["Mac Setup"].waitForExistence(timeout: 10),
                      "Mac Setup did not open.")

        let hosts = app.cells.containing(.button, identifier: "Connect")
        XCTAssertTrue(hosts.firstMatch.waitForExistence(timeout: 20),
                      "The saved Mac did not appear in Mac Setup.")
        XCTAssertEqual(hosts.count, 1, "Expected exactly one configured Mac for this smoke test.")
        let host = hosts.firstMatch
        if !host.staticTexts["ready"].exists {
            let connect = host.buttons["Connect"]
            XCTAssertTrue(connect.waitForExistence(timeout: 10), "Connect is unavailable.")
            connect.tap()
            allowLocalNetworkIfRequested()
        }
        XCTAssertTrue(host.staticTexts["ready"].waitForExistence(timeout: 30),
                      "The configured Mac did not become ready.")
        app.navigationBars["Mac Setup"].buttons.firstMatch.tap()
    }

    @MainActor
    private func allowLocalNetworkIfRequested() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        let allow = alert.buttons["Allow"]
        if allow.exists { allow.tap() }
    }
}
