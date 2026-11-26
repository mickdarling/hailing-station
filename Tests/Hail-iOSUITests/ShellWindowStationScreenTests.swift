import XCTest

final class ShellWindowStationScreenTests: XCTestCase, ShellWindowUITestSupport {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Station window qualification requires the simulator.")
        #endif
    }

    @MainActor
    func testOnboarding() {
        let app = launchStation(shellEnabled: true)
        captureBoth("onboarding", marker: "station.setup-mac", in: app)
        XCTAssertFalse(element("station.voice-dock.talk", in: app).isEnabled)
    }

    @MainActor
    func testFlagOffStation() {
        let app = launchStation(shellEnabled: false)
        XCTAssertFalse(element("station.listening-privacy-rail", in: app).exists)
        XCTAssertFalse(section("settings", in: app).exists)
        captureBoth("off", marker: "station.connection", in: app)
    }
}

@MainActor
private extension ShellWindowStationScreenTests {
    func captureBoth(_ state: String, marker: String, in app: XCUIApplication) {
        let previous = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = previous }
        for style in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = style
            let appearance = style == .light ? "light" : "dark"
            screen(marker, named: "s2-station-\(state)-\(appearance)", in: app)
        }
    }
}
