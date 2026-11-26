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
