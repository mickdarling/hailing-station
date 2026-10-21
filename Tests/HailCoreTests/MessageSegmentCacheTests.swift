import Foundation
import Testing
@testable import HailCore

/// #641 review: a message's links are parsed once per text, not on every chat update; a reply whose text grows is
/// parsed again, and the result is always exactly `MessageLinks.segments` of the current text.
@MainActor
@Suite struct MessageSegmentCacheTests {
    private func entry(_ id: String, _ text: String) -> ConversationEntry {
        ConversationEntry(id: id, speaker: .haili, text: text, endpointID: "mac", targetID: "tmux:a", date: .now)
    }

    @Test func eachTextIsParsedOnceAndAGrowingReplyAgain() {
        let cache = MessageSegmentCache()
        let first = entry("a", "See [the PR](https://example.com/pull/1).")
        let other = entry("b", "Plain words")
        for _ in 0..<5 {
            #expect(cache.segments(for: first) == MessageLinks.segments(first.text))
            #expect(cache.segments(for: other) == MessageLinks.segments(other.text))
        }
        #expect(cache.parses == 2)
        let grown = entry("a", first.text + " Also https://example.org/docs")
        #expect(cache.segments(for: grown) == MessageLinks.segments(grown.text))
        #expect(cache.parses == 3)
    }

    @Test func itStaysBoundedAndStillAnswersCorrectly() {
        let cache = MessageSegmentCache()
        for index in 0..<(3 * ConversationLog.limit) {
            let message = entry("m\(index)", "line \(index) https://example.com/\(index)")
            #expect(cache.segments(for: message) == MessageLinks.segments(message.text))
        }
        #expect(cache.parses == 3 * ConversationLog.limit)
    }
}
