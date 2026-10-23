import XCTest

/// #819: the conversation can take the whole station. Expanding grows the chat and hides the station cards while
/// keeping them mounted, the choice is remembered on the device, and a place the owner scrolled up to survives it.
final class ConversationFullScreenUITests: XCTestCase {
    private static let turns = 40

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("The seeded conversation runs in the simulator only.")
        }
    }

    @MainActor
    func testExpandingGrowsTheChatAndHidesTheStationCards() throws {
        let app = launch()
        let chat = try seededChat(in: app)
        let before = chat.frame.height
        let route = app.descendants(matching: .any)["station.audio-route"]
        XCTAssertTrue(route.exists)

        toggle(app).tap()
        try expectLabel("Show the station", in: app)
        XCTAssertGreaterThan(
            chat.frame.height, before + 100, "The chat did not grow: \(before) to \(chat.frame.height)."
        )
        XCTAssertFalse(route.isHittable, "A station card is still on screen while the chat is full screen.")
        // Nothing runs off the screen's edge (#819 review: the iPad header once pushed the chat past it).
        let edge = app.windows.firstMatch.frame.maxX
        XCTAssertLessThanOrEqual(chat.frame.maxX, edge + 1)
        XCTAssertLessThanOrEqual(toggle(app).frame.maxX, edge + 1)
        // The seed has no destination: its setup panel steps aside too.
        XCTAssertFalse(app.descendants(matching: .any)["station.availability"].isHittable)
        attach(app, named: "expanded")

        toggle(app).tap()
        try expectLabel("Expand the conversation", in: app)
        XCTAssertLessThan(chat.frame.height, before + 20, "The chat stayed full screen after collapsing.")
    }

    @MainActor
    func testTheChoiceIsRememberedOnThisDevice() throws {
        let app = launch()
        _ = try seededChat(in: app)
        toggle(app).tap()
        try expectLabel("Show the station", in: app)
        app.terminate()

        // Without the reset this time: the stored choice decides.
        let relaunched = launch(reset: false)
        _ = try seededChat(in: relaunched)
        try expectLabel("Show the station", in: relaunched)
        toggle(relaunched).tap()
        try expectLabel("Expand the conversation", in: relaunched)
    }

    /// #819 review: with Tap to talk and the privacy switch present (an invented talk card), expanding on an iPhone in
    /// portrait still grows the chat, and both stay on screen.
    @MainActor
    func testWithTapToTalkTheChatStillGrows() throws {
        let app = launch(talk: true)
        let chat = try seededChat(in: app)
        let before = chat.frame.height
        toggle(app).tap()
        try expectLabel("Show the station", in: app)
        attach(app, named: "talk-expanded")
        XCTAssertGreaterThan(chat.frame.height, before + 60, "The chat shrank: \(before) to \(chat.frame.height).")
        try expectReachable(["station.talk", "station.privacy-switch"], in: app)
    }

    /// #819 review: at accessibility text sizes nothing fits one screen, so expanding gives the chat most of it and the
    /// station scrolls to Tap to talk, rather than squeezing the chat below its collapsed height.
    @MainActor
    func testAtAccessibilitySizesExpandingNeverShrinksTheChat() throws {
        let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        let app = launch(talk: true, extra: large)
        let chat = try seededChat(in: app)
        let before = chat.frame.height
        toggle(app).tap()
        try expectLabel("Show the station", in: app)
        attach(app, named: "accessibility-expanded")
        XCTAssertGreaterThanOrEqual(chat.frame.height, before, "The chat shrank: \(before) to \(chat.frame.height).")
    }

    /// #819 review: in landscape, Tap to talk and the privacy switch sit beside the chat under a slim header, so
    /// expanding keeps most of the short screen for the chat and nothing leaves it.
    @MainActor
    func testInLandscapeTheChatKeepsMostOfTheScreen() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(talk: true)
        let chat = try seededChat(in: app)
        toggle(app).tap()
        try expectLabel("Show the station", in: app)
        let window = app.windows.firstMatch.frame
        attach(app, named: "landscape-expanded")
        XCTAssertGreaterThan(chat.frame.height, window.height * 0.55, "Chat \(chat.frame) in window \(window).")
        XCTAssertLessThanOrEqual(chat.frame.maxY, window.maxY + 1)
        XCTAssertLessThanOrEqual(chat.frame.maxX, window.maxX + 1)
        XCTAssertLessThanOrEqual(toggle(app).frame.maxX, window.maxX + 1)
        try expectReachable(["station.talk", "station.privacy-switch"], in: app)
    }

    /// The remembered choice never strands the owner: with no chat to carry the toggle (no destination, no seed),
    /// the station shows, with its setup panel.
    @MainActor
    func testARememberedChoiceWithoutAChatShowsTheStation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-reset-station-state", "-station.chatExpanded", "YES"]
        app.launch()
        let setup = app.descendants(matching: .any)["station.availability"]
        XCTAssertTrue(setup.waitForExistence(timeout: 20))
        XCTAssertTrue(setup.isHittable, "Setup is hidden with no way back to the station.")
        XCTAssertTrue(app.descendants(matching: .any)["station.audio-route"].exists)
    }

    @MainActor
    func testAPlaceScrolledUpToSurvivesExpanding() throws {
        let app = launch()
        let chat = try seededChat(in: app)
        chat.swipeDown()
        chat.swipeDown()
        let reread = app.staticTexts.allElementsBoundByIndex.last { $0.isHittable && $0.label.hasPrefix("Turn ") }
        let label = try XCTUnwrap(reread?.label.split(separator: ".").first.map { String($0) + "." })

        toggle(app).tap()
        try expectLabel("Show the station", in: app)
        let kept = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(kept.isHittable, "Expanding moved the chat away from what the owner scrolled up to.")
    }

    /// The reset also clears the remembered choice, so each test starts with the station showing.
    @MainActor
    private func launch(reset: Bool = true, talk: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += (reset ? ["-reset-station-state"] : []) + ["-seed-conversation", "\(Self.turns)"]
            + (talk ? ["-seed-talk-card"] : []) + extra
        app.launch()
        return app
    }

    /// Each element exists, can be tapped, and lies wholly inside the window.
    @MainActor
    private func expectReachable(_ identifiers: [String], in app: XCUIApplication) throws {
        let window = app.windows.firstMatch.frame
        for identifier in identifiers {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier) is missing.")
            XCTAssertTrue(element.isHittable, "\(identifier) cannot be tapped.")
            XCTAssertTrue(window.contains(element.frame), "\(identifier) \(element.frame) leaves window \(window).")
        }
    }

    @MainActor
    private func toggle(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "station.chat-expand").firstMatch
    }

    @MainActor
    private func expectLabel(_ label: String, in app: XCUIApplication) throws {
        let flipped = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: toggle(app))
        wait(for: [flipped], timeout: 5)
    }

    @MainActor
    private func seededChat(in app: XCUIApplication) throws -> XCUIElement {
        let chat = app.descendants(matching: .any)["station.chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        let newest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Turn \(Self.turns)."))
            .firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 60), "Seeding did not reach turn \(Self.turns).")
        return chat
    }

    @MainActor
    private func attach(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "conversation-full-screen-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
