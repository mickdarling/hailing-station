import XCTest

/// The redesign's Shell step (#1115): off by default, turned on from Labs, applied only after a relaunch, and the
/// station stays mounted while another section shows.
final class RedesignShellUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == nil {
            throw XCTSkip("Redesign shell coverage runs in the simulator matrix.")
        }
    }

    @MainActor
    func testShellAppliesOnlyAfterRelaunchAndKeepsTheStationMounted() {
        let app = XCUIApplication()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        // Landscape, so an iPad shows its sidebar without the system's reveal button.
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        addTeardownBlock { @MainActor in
            // A reset launch turns every redesign flag off again, so no other test sees the shell.
            app.terminate()
            app.launchArguments = ["-reset-station-state"]
            app.launch()
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }

        app.launchArguments = ["-reset-station-state"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 10))
        XCTAssertFalse(section("devices", in: app, isPad: isPad).exists, "The shell is off by default")

        turnOnShellInLabs(app)
        // Mid-run, the toggle changes nothing: the station is still today's, with no tabs or sidebar.
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 5))
        XCTAssertFalse(section("devices", in: app, isPad: isPad).exists, "The shell must wait for a relaunch")

        app.terminate()
        app.launchArguments = []
        app.launch()
        let devices = section("devices", in: app, isPad: isPad)
        XCTAssertTrue(devices.waitForExistence(timeout: 10), "The shell applies after a relaunch")
        let connection = app.descendants(matching: .any)["station.connection"]
        XCTAssertTrue(connection.waitForExistence(timeout: 10))

        devices.tap()
        XCTAssertTrue(app.descendants(matching: .any)["station.devices.mac-setup"].waitForExistence(timeout: 5))
        XCTAssertFalse(connection.exists, "The hidden station leaves the accessibility tree")

        section("station", in: app, isPad: isPad).tap()
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
    }

    @MainActor
    private func turnOnShellInLabs(_ app: XCUIApplication) {
        let labs = app.buttons["Labs"]
        for _ in 0..<6 where !(labs.exists && labs.isHittable) { app.swipeUp() }
        XCTAssertTrue(labs.isHittable, "Labs is reachable from the station tools")
        // A tap while a swipe still scrolls only stops the scroll, so tap again if Labs didn't open.
        let title = app.navigationBars["Labs"]
        labs.tap()
        if !title.waitForExistence(timeout: 3), labs.exists, labs.isHittable { labs.tap() }
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Labs opens")

        let toggle = app.switches["station.redesign.shell"]
        for _ in 0..<4 where !(toggle.exists && toggle.isHittable) { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "Off by default")
        // The switch itself sits at the trailing edge; a tap on the row's label does not flip it.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["station.redesign.shell.pending"].exists, "The row says a relaunch applies it")

        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// A tab on iPhone, a sidebar row on iPad. The row's icon carries its identifier too but isn't hittable, so
    /// the row is found by its title.
    @MainActor
    private func section(_ name: String, in app: XCUIApplication, isPad: Bool) -> XCUIElement {
        isPad ? app.staticTexts["station.section.\(name)"].firstMatch : app.buttons["station.tab.\(name)"].firstMatch
    }
}
