import XCTest

/// #717: a long ambient session, past the chat log's 200-entry cap, must keep its newest message on screen, and
/// trimming the oldest entries must never scroll the chat past the end of its content (a blank chat).
final class LongConversationUITests: XCTestCase {
    private static let turns = 470
    /// Points the chat may sit past its content's end: rounding only. A blank chat is a whole viewport or more.
    private static let overshootTolerance = 8

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("The seeded conversation runs in the simulator only.")
        }
    }

    /// Overheard turns shown: every turn is in the chat, and the log trims one for each past its 200th.
    @MainActor
    func testNewestMessageStaysVisiblePastTheLogCap() throws {
        let app = launch(["-overheard.show", "YES", "-overheard.whose", "everyone"])
        try assertNewestVisible(turn: Self.turns, in: app, named: "overheard-shown")
    }

    /// Overheard turns hidden (the default), and the session ends with guests talking among themselves at a spoken
    /// pace: each hidden turn trims a shown one from the top, so the chat shrinks with nothing new at its bottom.
    @MainActor
    func testNewestShownMessageStaysVisibleWhileHiddenTurnsTrimTheLog() throws {
        let tail = 60
        let app = launch(["-overheard.show", "NO", "-seed-overheard-tail", "\(tail)", "-seed-tail-ms", "300"])
        // The newest shown turn before the tail: the two before it are overheard too (the seed's turn % 4 mix).
        try assertNewestVisible(turn: Self.turns - tail - 2, in: app, named: "hidden-tail", settle: 25)
    }

    /// The owner scrolled up to reread: messages that keep arriving, and trims, leave their place alone.
    @MainActor
    func testScrolledUpOwnerKeepsTheirPlace() throws {
        let app = launch([
            "-overheard.show", "YES", "-overheard.whose", "everyone",
            "-seed-overheard-tail", "30", "-seed-tail-ms", "300"
        ])
        let chat = app.descendants(matching: .any)["station.chat"]
        let marker = Self.turn(Self.turns - 30, in: app)
        XCTAssertTrue(marker.waitForExistence(timeout: 180))
        chat.swipeDown()
        chat.swipeDown()
        let reread = app.staticTexts.allElementsBoundByIndex.last { $0.isHittable && $0.label.hasPrefix("Turn ") }
        let label = try XCTUnwrap(reread?.label.split(separator: ".").first.map { String($0) + "." })
        XCTAssertTrue(Self.turn(Self.turns, in: app).waitForExistence(timeout: 30))
        _ = app.staticTexts["station.never-present"].waitForExistence(timeout: 3)
        let kept = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(kept.isHittable, "The chat moved away from what the owner scrolled up to.")
        XCTAssertFalse(Self.turn(Self.turns, in: app).isHittable, "The chat jumped to the newest message.")
    }

    @MainActor
    private static func turn(_ turn: Int, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Turn \(turn).")).firstMatch
    }

    @MainActor
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-reset-station-state", "-seed-conversation", "\(Self.turns)"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func assertNewestVisible(
        turn: Int, in app: XCUIApplication, named name: String, settle: TimeInterval = 3
    ) throws {
        let chat = app.descendants(matching: .any)["station.chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        let newest = Self.turn(turn, in: app)
        XCTAssertTrue(newest.waitForExistence(timeout: 180), "Seeding did not reach turn \(turn).")
        // The seed's remaining frames, then the last scroll, settle.
        _ = app.staticTexts["station.never-present"].waitForExistence(timeout: settle)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "long-conversation-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(
            newest.frame.intersects(chat.frame) && newest.isHittable,
            "The newest message is not on screen: its frame \(newest.frame) vs the chat's \(chat.frame)."
        )
        let probe = app.descendants(matching: .any)["station.chat.overshoot"]
        XCTAssertTrue(probe.exists)
        let overshoot = Int(probe.value as? String ?? "") ?? .max
        XCTAssertLessThanOrEqual(
            overshoot, Self.overshootTolerance,
            "The chat scrolled \(overshoot) pt past its content's end (#717); the chat card is \(chat.frame.height) pt."
        )
    }
}
