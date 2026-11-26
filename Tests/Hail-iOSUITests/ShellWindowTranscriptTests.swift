#if STATION_UI_FIXTURES
import XCTest

final class ShellWindowTranscriptTests: XCTestCase, ShellWindowUITestSupport {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Station display qualification requires a simulator.")
        #endif
    }

    @MainActor
    func testDocumentMatchesStationFramesInLightAndDark() {
        let app = application()
        let previous = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = previous }
        for style in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = style
            for state in ["ready", "listening", "held", "refused"] {
                launchDocument(state, in: app)
                let name = "station-\(state)" + (style == .dark ? "-dark-ours" : "-ours")
                screen("station.chat", named: name, in: app)
                app.terminate()
            }
        }
    }

    @MainActor
    func testHeardTurnsExposeTheirOwnSpeakerAndDispatch() {
        let app = application()
        launchDocument("attribution", in: app)
        let headings = element("station.chat", in: app).descendants(matching: .any)
            .matching(identifier: "station.transcript.heading")
        for (speaker, dispatch) in [("You", "Heard. Send unconfirmed."), ("Speaker B", "Heard but not sent.")] {
            let label = "Speaker: \(speaker)."
            let badge = NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)",
                                    "station.transcript.speaker", label, label)
            let heading = headings.containing(badge).firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 5), label)
            let chip = element("station.transcript.dispatch", in: heading)
            XCTAssertTrue(chip.exists)
            XCTAssertTrue(chip.label == dispatch || chip.value as? String == dispatch, chip.debugDescription)
        }
    }

    @MainActor
    func testOnlyOwnerRowsSitOnTheRight() {
        let app = application()
        launchDocument("attribution", in: app)
        let chat = element("station.chat", in: app)
        let owner = element("station.transcript.row.request", in: chat)
        XCTAssertTrue(owner.waitForExistence(timeout: 5))
        let ownerFrame = owner.frame
        XCTAssertFalse(ownerFrame.isEmpty)
        for id in ["other", "reply"] {
            let row = element("station.transcript.row.\(id)", in: chat)
            XCTAssertTrue(row.waitForExistence(timeout: 5), id)
            let frame = row.frame
            XCTAssertFalse(frame.isEmpty, id)
            XCTAssertGreaterThan(ownerFrame.minX, frame.minX, id)
            XCTAssertGreaterThan(ownerFrame.maxX, frame.maxX, id)
        }
    }

    @MainActor
    func testReplyAudioProblemNoticeHasTheClassicAccessibleText() {
        let app = application()
        let cases: [(StationTranscriptSeed, String?)] = [
            (.decodeFailed, "Audio couldn't play"),
            (.playbackFailed, "Audio couldn't play"),
            (.incompleteAudio, "Audio didn't arrive in full"),
            (.discardedAudio, "Audio not kept while paused"),
            (.ready, nil)
        ]
        for (state, expected) in cases {
            launchDocument(state.rawValue, in: app)
            let chat = element("station.chat", in: app)
            XCTAssertTrue(element("station.transcript.details", in: chat).waitForExistence(timeout: 5))
            let notices = chat.descendants(matching: .any).matching(identifier: "chat.reply.audio-problem")
            if let expected {
                let reading = NSPredicate(format: "elementType != %@ AND (label == %@ OR value == %@)",
                                          NSNumber(value: XCUIElement.ElementType.image.rawValue), expected, expected)
                let matches = notices.matching(reading)
                XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), state.rawValue)
                XCTAssertEqual(matches.count, 1, "Only the affected reply should expose the notice")
                let reply = element("station.transcript.row.reply", in: chat)
                XCTAssertTrue(element("chat.reply.audio-problem", in: reply).exists)
                XCTAssertTrue(element("station.transcript.details", in: reply).exists)
            } else {
                XCTAssertFalse(notices.firstMatch.exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testOnAirAccessibilityFollowsCaptureAndPrivacy() {
        let app = application()
        let title = ["mac": "Mac", "ipad": "iPad", "iphone": "iPhone"][device] ?? device
        let cases = [("listening", "Listening on this \(title), on air."), ("recording", "Recording, on air."),
                     ("private", "Private"), ("pending", "Recording may be on."), ("ready", "Microphone off.")]
        for (state, prefix) in cases {
            launchDocument(state, in: app)
            let rail = element("station.listening-privacy-rail", in: app)
            XCTAssertTrue(rail.waitForExistence(timeout: 5))
            XCTAssertTrue(rail.label.hasPrefix(prefix), rail.label)
            XCTAssertEqual(rail.label.contains(", on air"), state == "listening" || state == "recording")
            app.terminate()
        }
    }

    @MainActor
    func testDeliveryDetailsShowTheReplyDestination() {
        let app = application()
        launchDocument("ready", in: app)
        let details = element("station.transcript.details", in: app)
        reveal(details, in: app)
        activate(details)
        let sheet = element("station.transcript.delivery", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        for name in ["Studio Mac", "Workbench"] {
            let field = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name)
            XCTAssertTrue(sheet.descendants(matching: .any).matching(field).firstMatch.exists, name)
        }
        activate(app.buttons["Done"].firstMatch)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }
}

@MainActor
extension ShellWindowTranscriptTests {
    func application() -> XCUIApplication {
        #if os(macOS)
        let app = XCUIApplication(bundleIdentifier: "com.mickdarling.Hail-macOS-shell-tests")
        #else
        let app = XCUIApplication()
        let original = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = device == "ipad" ? .landscapeLeft : .portrait
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = original }
        #endif
        let reset = baseArguments + ["-reset-station-state"]
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = reset
            app.launch()
            app.terminate()
        }
        return app
    }

    func launchDocument(_ state: String, in app: XCUIApplication) {
        app.launchArguments = baseArguments + ["-reset-station-state", "-seed-navigation-shell",
                                               "-seed-station-state", state]
        launchStation(app)
        XCTAssertTrue(element("station.chat", in: app).waitForExistence(timeout: 10))
    }
}
#endif
