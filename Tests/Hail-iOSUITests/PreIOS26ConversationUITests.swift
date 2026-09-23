import XCTest

final class PreIOS26ConversationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if #available(iOS 26.0, *) {
            throw XCTSkip("The compatibility conversation check requires a pre-iOS-26 device.")
        }
    }

    @MainActor
    func testRestoredDestinationExposesTapToTalkWithoutAnAvailabilityNotice() throws {
        guard let targetLabel = ProcessInfo.processInfo.environment["HAIL_UI_TARGET_LABEL"] else {
            throw XCTSkip("Set HAIL_UI_TARGET_LABEL to the configured physical target label.")
        }
        let app = XCUIApplication()
        app.launch()

        assertDestination(targetLabel, in: app)
        XCTAssertFalse(app.staticTexts["Requires iOS 26"].exists)
        XCTAssertTrue(app.buttons["station.talk"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testTapToTalkTranscribesAndSendsWithTheCompatibilityRecognizer() throws {
        guard let targetLabel = ProcessInfo.processInfo.environment["HAIL_UI_TARGET_LABEL"] else {
            throw XCTSkip("Set HAIL_UI_TARGET_LABEL to the configured physical target label.")
        }
        let app = XCUIApplication()
        installPermissionHandler()
        app.launch()
        assertDestination(targetLabel, in: app)

        let start = app.buttons["station.talk"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        triggerSequentialPermissionHandlers(in: app, talkButton: start)
        let stop = app.buttons["station.talk"]
        XCTAssertTrue(waitForLabel("Tap to finish", on: stop, timeout: 30))
        let status = app.staticTexts["transcription.status"]
        XCTAssertTrue(waitForLabel("Receiving audio", on: status, timeout: 10))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                    "speech",
                    "test"
                )
            ).firstMatch.waitForExistence(timeout: 30),
            "The compatibility recognizer did not publish the spoken test phrase."
        )
        stop.tap()

        XCTAssertTrue(
            waitForAnyLabel(["Waiting for reply…", "Reply received"], on: status, timeout: 10),
            "The conversation did not reach a successful post-send state."
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func triggerSequentialPermissionHandlers(
        in app: XCUIApplication,
        talkButton: XCUIElement
    ) {
        // Microphone and speech-recognition permission arrive as separate alerts on a clean device.
        for _ in 0..<2 {
            app.tap()
            if waitForLabel("Tap to finish", on: talkButton, timeout: 5) { return }
        }
    }

    @MainActor
    private func assertDestination(_ label: String, in app: XCUIApplication) {
        let destination = app.buttons["station.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        let selected = destinationValuePredicate(for: label)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: selected, object: destination)],
                timeout: 30
            ),
            .completed
        )
    }

    @MainActor
    private func installPermissionHandler() {
        addUIInterruptionMonitor(withDescription: "Microphone or speech permission") { alert in
            let text = alert.staticTexts.allElementsBoundByIndex
                .map(\.label)
                .joined(separator: " ")
                .lowercased()
            let expected = text.contains("microphone")
                || (text.contains("speech") && text.contains("recognition"))
            guard expected else { return false }
            for label in ["Allow", "Continue", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    @MainActor
    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForAnyLabel(
        _ labels: [String], on element: XCUIElement, timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label IN %@", labels)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
