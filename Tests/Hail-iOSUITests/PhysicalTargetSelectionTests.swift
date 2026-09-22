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
    func testBootstrapsHostAndSelectsConfiguredPhysicalTarget() throws {
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            throw XCTSkip("The host bootstrap test requires a physical iPhone or iPad.")
        }
        guard let hostName = ProcessInfo.processInfo.environment["HAIL_UI_HOST_NAME"],
              let hostURL = ProcessInfo.processInfo.environment["HAIL_UI_HOST_URL"],
              let targetLabel = ProcessInfo.processInfo.environment["HAIL_UI_TARGET_LABEL"] else {
            throw XCTSkip("Set HAIL_UI_HOST_NAME, HAIL_UI_HOST_URL, and HAIL_UI_TARGET_LABEL.")
        }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 10))
        app.buttons["Connections"].tap()
        XCTAssertTrue(app.navigationBars["Connectivity Lab"].waitForExistence(timeout: 10))

        let configuredHost = configuredHostCell(name: hostName, url: hostURL, in: app)
        if !configuredHost.exists, app.staticTexts[hostName].exists {
            let savedHost = app.cells.containing(.staticText, identifier: hostName).firstMatch
            XCTAssertTrue(savedHost.waitForExistence(timeout: 5))
            savedHost.buttons["Edit"].tap()
            replaceText(in: app.textFields["WebSocket URL"], with: hostURL)
            app.buttons["Save host"].tap()
        } else if !configuredHost.exists {
            let name = app.textFields["Name"]
            let url = app.textFields["WebSocket URL"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText(hostName)
            replaceText(in: url, with: hostURL)
            app.buttons["Add host"].tap()
            XCTAssertTrue(app.staticTexts[hostName].waitForExistence(timeout: 10))
        }

        let host = configuredHostCell(name: hostName, url: hostURL, in: app)
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.buttons["Connect"].tap()
        allowLocalNetworkIfRequested()
        XCTAssertTrue(host.staticTexts["ready"].waitForExistence(timeout: 30))
        app.navigationBars["Connectivity Lab"].buttons.firstMatch.tap()
        selectTarget(targetLabel, in: app)
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
    func testRestoresConfiguredPhysicalTargetAfterRelaunch() throws {
        let app = try launchAndSelectTarget()
        guard let targetLabel = ProcessInfo.processInfo.environment["HAIL_UI_TARGET_LABEL"] else {
            throw XCTSkip("Set HAIL_UI_TARGET_LABEL to a connected host and target label.")
        }

        app.terminate()
        app.launch()

        XCTAssertTrue(
            waitForDestination(targetLabel, in: app, timeout: 30),
            "The remembered target did not restore after relaunch. Current UI: \(app.debugDescription)"
        )
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

        selectTarget(targetLabel, in: app)
        return app
    }

    @MainActor
    private func selectTarget(_ label: String, in app: XCUIApplication) {
        let targetButton = destinationButton(in: app)
        XCTAssertTrue(targetButton.waitForExistence(timeout: 30))
        if targetButton.value as? String == label { return }
        targetButton.tap()

        let target = app.buttons[label]
        XCTAssertTrue(
            target.waitForExistence(timeout: 30),
            "Configured target was unavailable. Current UI: \(app.debugDescription)"
        )
        target.tap()
        XCTAssertTrue(waitForDestination(label, in: app, timeout: 10))
    }

    @MainActor
    private func destinationButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["station.destination"]
    }
}

private extension PhysicalTargetSelectionTests {
    @MainActor
    func waitForDestination(_ label: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: destinationButton(in: app))
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    func replaceText(in field: XCUIElement, with replacement: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(replacement)
    }

    @MainActor
    func configuredHostCell(name: String, url: String, in app: XCUIApplication) -> XCUIElement {
        app.cells
            .containing(.staticText, identifier: name)
            .containing(.staticText, identifier: url)
            .firstMatch
    }

    @MainActor
    func allowLocalNetworkIfRequested() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        let allow = alert.buttons["Allow"]
        if allow.exists { allow.tap() }
    }
}
