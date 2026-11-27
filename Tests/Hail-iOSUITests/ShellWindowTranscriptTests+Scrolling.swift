#if STATION_UI_FIXTURES
import XCTest

extension ShellWindowTranscriptTests {
    #if os(iOS)
    @MainActor
    func testReplyGrowingDuringDragOffersJumpWhenGestureEndsAboveLatest() {
        let app = application()
        launchDocument("scrolling", in: app)
        let chat = element("station.chat", in: app)
        assertVisible("Reply 20.", in: chat)
        activate(app.buttons["Extend on drag"])
        let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -24))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        let jump = app.buttons["station.transcript.jump-to-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        activate(jump)
        assertVisible("Stream paragraph 16.", in: chat)
    }
    #endif

    @MainActor
    func testPinnedDocumentFollowsHeardTurnsRepliesAndStreamedGrowth() {
        let app = application()
        launchDocument("scrolling", in: app)
        let chat = element("station.chat", in: app)
        assertVisible("Reply 20.", in: chat)
        activate(app.buttons["Append turn"])
        assertVisible("Heard 21.", in: chat)
        activate(app.buttons["Append turn"])
        assertVisible("Reply 22.", in: chat)
        activate(app.buttons["Extend reply"])
        assertVisible("Stream paragraph 16.", in: chat)
        activate(app.buttons["Extend reply"])
        assertVisible("Stream paragraph 32.", in: chat)
        XCTAssertFalse(element("station.transcript.jump-to-latest", in: app).exists)
    }

    @MainActor
    func testReadingPositionSurvivesAppendsUntilJumpToLatest() {
        let app = application()
        launchDocument("scrolling", in: app)
        let chat = element("station.chat", in: app)
        let marker = line("Heard 9.", in: chat)
        scrollBack(to: marker, in: chat)
        let jump = app.buttons["station.transcript.jump-to-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertEqual(jump.label, "Jump to latest")
        let readingY = marker.frame.midY
        activate(app.buttons["Extend reply"])
        XCTAssertEqual(marker.frame.midY, readingY, accuracy: 2)
        activate(app.buttons["Append turn"])
        XCTAssertTrue(marker.isHittable)
        XCTAssertEqual(marker.frame.midY, readingY, accuracy: 2)
        let newest = line("Heard 21.", in: chat)
        XCTAssertFalse(newest.exists && newest.isHittable && newest.frame.intersects(chat.frame))
        activate(jump)
        assertVisible("Heard 21.", in: chat)
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
        activate(app.buttons["Append turn"])
        assertVisible("Reply 22.", in: chat)
    }
}

@MainActor
private extension ShellWindowTranscriptTests {
    func line(_ text: String, in chat: XCUIElement) -> XCUIElement {
        chat.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
    }

    func assertVisible(_ text: String, in chat: XCUIElement) {
        let row = line(text, in: chat)
        waitUntilHittable(row)
        XCTAssertTrue(chat.frame.contains(CGPoint(x: row.frame.midX, y: row.frame.midY)), text)
    }

    func scrollBack(to marker: XCUIElement, in chat: XCUIElement) {
        for _ in 0..<16 {
            let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            #if os(macOS)
            start.scroll(byDeltaX: 0, deltaY: chat.frame.height * 0.45)
            #else
            let end = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            #endif
            if marker.exists && marker.isHittable && chat.frame.contains(marker.frame) { return }
        }
        XCTFail("The history turn should be visible after scrolling back")
    }
}
#endif
