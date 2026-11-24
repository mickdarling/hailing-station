import XCTest

/// Shared by Hail-macOSUITests and Hail-iOSUITests. Select only the in-memory peer's target and exercise
/// presentation controls. Never press Talk, Interrupt, the system Paste button or Send.
final class ShellWindowStationScreenTests: XCTestCase, ShellWindowUITestSupport {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Station window qualification requires the simulator.")
        #endif
    }

    @MainActor
    func testReadyStationAndItsControls() {
        let app = seeded("ready")
        confirmFixtureDestination(in: app)
        let turn = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Turn 4.'")).firstMatch
        XCTAssertTrue(turn.waitForExistence(timeout: 8))
        captureBoth("ready", marker: "station.talk", in: app)

        let rail = element("station.listening-privacy-rail", in: app)
        activate(rail)
        XCTAssertTrue(element("station.rail.detail", in: app).waitForExistence(timeout: 5))
        activate(rail)
        XCTAssertTrue(element("station.rail.detail", in: app).waitForNonExistence(timeout: 5))

        activate(element("station.voice-dock.paste", in: app))
        XCTAssertTrue(element("station.paste", in: app).waitForExistence(timeout: 5))
        activateButton("Done", in: app.buttons)
        XCTAssertTrue(element("station.paste", in: app).waitForNonExistence(timeout: 5))
        activate(element("station.chat-expand", in: app))
        activate(element("station.chat-expand", in: app))
        activate(element("station.voice-dock.more", in: app))
        activate(app.descendants(matching: .any).matching(identifier: "Audio routes").firstMatch)
        XCTAssertTrue(element("settings.audio.overview", in: app).waitForExistence(timeout: 5))
        activateButton("Done", in: app.buttons)
    }

    @MainActor
    func testOfflineAndRecovery() {
        let app = seeded("offline")
        captureBoth("offline", marker: "station.review-recovery", in: app)
        activate(element("station.review-recovery", in: app))
        captureBoth("recovery", marker: "recovery.chooseDestination", in: app)
        activate(element("recovery.chooseDestination", in: app))
        activateButton("Done", in: app.buttons)
        waitUntilHittable(stationDestinationPicker(in: app))
    }

    @MainActor
    func testRefusedStation() {
        let app = seeded("refused")
        confirmFixtureDestination(in: app)
        let refused = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "The session refused the request.", "The session refused the request.")
        XCTAssertTrue(app.descendants(matching: .any).matching(refused).firstMatch.waitForExistence(timeout: 8))
        captureBoth("refused", marker: "station.chat", in: app)
    }

    @MainActor
    func testHeldStation() {
        let app = seeded("held")
        confirmFixtureDestination(in: app)
        XCTAssertTrue(app.buttons["Resume"].firstMatch.waitForExistence(timeout: 8))
        captureBoth("held", marker: "station.chat", in: app)
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
    func seeded(_ state: String) -> XCUIApplication {
        launchStation(shellEnabled: true, arguments: ["-seed-station-screen", state, "-seed-conversation", "4"])
    }

    func confirmFixtureDestination(in app: XCUIApplication) {
        choose("station", in: app)
        activate(stationDestinationPicker(in: app))
        activate(element("Studio Mac · Workbench", in: app))
        XCTAssertTrue(app.buttons["station.talk"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["station.talk"].isEnabled)
    }

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
