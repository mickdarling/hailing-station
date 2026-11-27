#if STATION_UI_FIXTURES
import XCTest

/// Shared by Hail-macOSUITests and Hail-iOSUITests. Select only the in-memory peer's target and exercise
/// presentation controls. Never press Talk, Interrupt, the system Paste button or Send.
final class ShellWindowStationStateScreenshotTests: XCTestCase, ShellWindowUITestSupport {
    @MainActor
    func testTalkButtonSnapshotsInBothAppearances() {
        let previous = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = previous }
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            for state in [StationTranscriptSeed.ready, .awaitingReply, .recording] {
                let app = launchStation(arguments: ["-seed-navigation-shell", "-seed-station-state", state.rawValue])
                let button = app.buttons["station.talk"]
                XCTAssertTrue(button.waitForExistence(timeout: 8))
                XCTAssertEqual(button.isEnabled, state.dock.isEnabled)
                XCTAssertEqual(button.label, state.dock.label)
                let snapshot = XCTAttachment(screenshot: button.screenshot())
                let scheme = appearance == .dark ? "dark" : "light"
                snapshot.name = "\(device)-talk-\(state.rawValue)-\(scheme)"
                snapshot.lifetime = .keepAlways
                add(snapshot)
                app.terminate()
            }
        }
    }

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
        let turn = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                                                        "Turn 4.", "Turn 4.")).firstMatch
        XCTAssertTrue(turn.waitForExistence(timeout: 8))
        captureBoth("ready", marker: "station.talk", in: app)

        let rail = element("station.listening-privacy-rail", in: app)
        activate(rail)
        XCTAssertTrue(element("station.rail.detail", in: app).waitForExistence(timeout: 5))
        activate(rail)
        XCTAssertTrue(element("station.rail.detail", in: app).waitForNonExistence(timeout: 5))

        // The fixture advertises no privacy capability; this button opens the owner's details.
        activate(element("station.voice-dock.privacy", in: app))
        XCTAssertTrue(element("station.rail.detail", in: app).waitForExistence(timeout: 5))
        activate(rail)

        activate(element("station.voice-dock.paste", in: app))
        XCTAssertTrue(element("station.paste", in: app).waitForExistence(timeout: 5))
        activateButton("Done", in: app.buttons)
        XCTAssertTrue(element("station.paste", in: app).waitForNonExistence(timeout: 5))
        activate(element("station.chat-expand", in: app))
        activate(element("station.chat-expand", in: app))
        activate(element("station.voice-dock.more", in: app))
        activate(element("station.voice-dock.routes", in: app))
        XCTAssertTrue(element("settings.audio.overview", in: app).waitForExistence(timeout: 5))
        activateButton("Done", in: app.buttons)
        activate(element("station.voice-dock.more", in: app))
        activate(element("station.voice-dock.listening", in: app))
        XCTAssertTrue(element("station.rail.detail", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testOfflineAndRecovery() {
        let app = seeded("offline")
        let recovery = element("station.review-recovery", in: app)
        XCTAssertTrue(recovery.waitForExistence(timeout: 8))
        captureBoth("offline", marker: "station.connection", in: app)
        reveal(recovery, in: app)
        activate(recovery)
        captureBoth("recovery", marker: "recovery.chooseDestination", in: app)
        activate(element("recovery.chooseDestination", in: app))
        activateButton("Done", in: app.buttons)
        waitUntilHittable(destinationPicker(in: app))
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
        captureBoth("held", marker: "station.playback-held", in: app)
    }

    @MainActor
    func testHeldReplyHasNoAudioControlsInTheRedesignedTranscript() {
        let app = launchStation(shellEnabled: true, arguments: ["-seed-station-screen", "held",
                                                                 "-seed-conversation", "1"])
        confirmFixtureDestination(in: app)
        XCTAssertTrue(element("station.playback-held", in: app).waitForExistence(timeout: 8))
        let transcript = element("station.chat", in: app)
        XCTAssertTrue(element("station.transcript.details", in: transcript).waitForExistence(timeout: 8))
        for title in ["Replay", "Pause", "Resume", "Mute", "Unmute"] {
            XCTAssertFalse(transcript.buttons[title].firstMatch.exists, title)
        }
        XCTAssertFalse(element("station.transcript.audio-status", in: transcript).exists)
        XCTAssertFalse(transcript.staticTexts["Audio played"].firstMatch.exists)
    }
}

@MainActor
private extension ShellWindowStationStateScreenshotTests {
    func seeded(_ state: String) -> XCUIApplication {
        launchStation(shellEnabled: true, arguments: ["-seed-station-screen", state, "-seed-conversation", "4"])
    }

    func confirmFixtureDestination(in app: XCUIApplication) {
        choose("station", in: app)
        activate(destinationPicker(in: app))
        activate(element("Studio Mac · Workbench", in: app))
        XCTAssertTrue(app.buttons["station.talk"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["station.talk"].isEnabled)
    }
}
#endif
