import XCTest

final class PhysicalTranscriptionSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureStartsAndStopsWithoutTerminatingTheApp() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The audio-capture smoke test requires a physical iPhone or iPad.")
        #else
        let app = XCUIApplication()
        installPermissionHandler()
        app.launch()

        let transcriptionLink = app.buttons["Live transcription (#6)"]
        XCTAssertTrue(transcriptionLink.waitForExistence(timeout: 10))
        transcriptionLink.tap()

        let startButton = app.buttons["Tap to talk"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        app.tap() // Gives XCTest an event with which to invoke a pending interruption monitor.

        let stopButton = app.buttons["Tap to finish"]
        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 90),
            "Capture did not reach the listening state. Current UI: \(app.debugDescription)"
        )
        stopButton.tap()

        XCTAssertTrue(app.buttons["Tap to talk"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.state, .runningForeground)
        #endif
    }

    @MainActor
    private func installPermissionHandler() {
        addUIInterruptionMonitor(withDescription: "Microphone or speech permission") { alert in
            for label in ["Allow", "Continue", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }
}
