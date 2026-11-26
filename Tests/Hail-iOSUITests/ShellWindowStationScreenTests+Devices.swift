import XCTest

#if STATION_UI_FIXTURES
#if os(macOS)
extension ShellWindowStationScreenTests {
    @MainActor
    func testClassicMacSetupStillOpensFromTheStation() {
        let app = launchStation(shellEnabled: false)
        let setup = element("station.mac-setup-tool", in: app)
        reveal(setup, in: app)
        activate(setup)

        let window = stationWindow(in: app)
        XCTAssertTrue(text("Add a Mac address to begin.", in: window).waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["Add Mac"].exists)
        let back = element("station.tool-back", in: window)
        activate(back)
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
    }

    @MainActor
    func testDevicesShowsConfiguredMacsAndUpdatesTheirConnectionStateInPlace() {
        let app = launchStation(shellEnabled: true, arguments: ["-seed-station-screen", "destinations"])
        choose("devices", in: app)
        let page = element("station.devices.setup-page", in: stationWindow(in: app))
        let studio = element("station.devices.host.ui-test-seed", in: page)
        let annex = element("station.devices.host.annex", in: page)

        XCTAssertTrue(text("Studio Mac", in: studio).waitForExistence(timeout: 8))
        XCTAssertTrue(text("Annex Mac", in: annex).waitForExistence(timeout: 8))
        XCTAssertTrue(text("ready", in: studio).waitForExistence(timeout: 8))
        XCTAssertTrue(text("Workbench · tmux · Running", in: studio).waitForExistence(timeout: 8))
        XCTAssertTrue(text("Archive · tmux · Stopped", in: studio).exists)

        activate(studio.buttons["Disconnect"])
        XCTAssertTrue(text("disconnected", in: studio).waitForExistence(timeout: 8))
        XCTAssertTrue(text("ready", in: annex).waitForExistence(timeout: 8))
        activate(studio.buttons["Edit"])
        let name = studio.textFields.matching(NSPredicate(format: "value == %@", "Studio Mac")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        waitUntilHittable(studio.buttons["Save Mac"])
    }

    @MainActor
    private func text(_ value: String, in row: XCUIElement) -> XCUIElement {
        row.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", value, value)).firstMatch
    }
}
#endif
#endif
