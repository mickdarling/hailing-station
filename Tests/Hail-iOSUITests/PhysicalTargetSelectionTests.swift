import XCTest

final class PhysicalTargetSelectionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSelectsConfiguredPhysicalTarget() throws {
        let app = try launchAndSelectTarget()

        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testExercisesReplyControlsForConfiguredTarget() throws {
        guard ProcessInfo.processInfo.environment["HAIL_UI_EXERCISE_REPLY_CONTROLS"] == "1" else {
            throw XCTSkip("Set HAIL_UI_EXERCISE_REPLY_CONTROLS=1 and inject a reply from the host.")
        }
        let app = try launchAndSelectTarget()
        let replay = app.buttons["Replay"]
        XCTAssertTrue(replay.waitForExistence(timeout: 60), "No host reply arrived for control testing.")

        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))

        replay.tap()
        XCTAssertTrue(app.staticTexts["Replaying"].waitForExistence(timeout: 5))

        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        mute.tap()
        let unmute = app.buttons["Unmute"]
        XCTAssertTrue(unmute.waitForExistence(timeout: 5))
        unmute.tap()
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func launchAndSelectTarget() throws -> XCUIApplication {
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            throw XCTSkip("The host-backed target selection test requires a physical iPhone or iPad.")
        }
        guard let targetLabel = ProcessInfo.processInfo.environment["HAIL_UI_TARGET_LABEL"],
              !targetLabel.isEmpty else {
            throw XCTSkip("Set HAIL_UI_TARGET_LABEL to a connected host and target label.")
        }

        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 10))

        let targetButton = app.buttons["Target"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 30))
        targetButton.tap()

        let target = app.buttons[targetLabel]
        XCTAssertTrue(
            target.waitForExistence(timeout: 30),
            "Configured target was unavailable. Current UI: \(app.debugDescription)"
        )
        target.tap()

        XCTAssertTrue(app.staticTexts[targetLabel].waitForExistence(timeout: 10))
        return app
    }
}
