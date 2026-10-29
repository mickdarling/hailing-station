import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct SessionUpdateConversationTests {
    private func event(_ update: UUID = UUID(), endpoint: String = "mac", target: String? = "tmux:build",
                       text: String = "Build passed.") -> HostReplyEvent {
        HostReplyEvent(endpointID: endpoint, frame: Frame(
            timestamp: 1, target: target, source: "host", payload: .control(.sessionUpdate(
                update: update, session: "Build", priority: "info", text: text,
                card: "[Review](https://example.invalid/pull/1)"
            ))
        ))
    }

    @Test func cardsKeepSessionAttributionAndDetailsInTheirOwnThread() throws {
        let log = ConversationLog(now: { Date(timeIntervalSince1970: 100) })
        log.noteSent("Check it", pasted: "draft", endpointID: "mac", targetID: "tmux:build")
        log.noteSessionUpdate(event())
        let entry = try #require(log.entries.last)
        #expect(entry.targetID == "tmux:build" && entry.source == "Build")
        #expect(entry.updatePriority == "info" && !entry.spoken)
        #expect(entry.metadata == "[Review](https://example.invalid/pull/1)")
        #expect(entry.metadataBlocks == MessageMarkdown.blocks(try #require(entry.metadata)))
        #expect(entry.date == Date(timeIntervalSince1970: 100))
        #expect(log.entries.first?.pasteState == .pending)
        #expect(log.entries(endpointID: "mac", targetID: "tmux:other", addressed: true).isEmpty)
    }

    @Test func receiptIdentityIncludesHostAndDuplicatesNeverRewriteTheCard() {
        let log = ConversationLog()
        let update = UUID()
        log.noteSessionUpdate(event(update))
        log.noteSessionUpdate(event(update, text: "Changed duplicate"))
        log.noteSessionUpdate(event(update, endpoint: "other-mac"))
        #expect(log.entries.map(\.text) == ["Build passed.", "Build passed."])
        #expect(log.entries.map(\.endpointID) == ["mac", "other-mac"])
    }

    @Test func duplicateReceiptSurvivesVisibleHistoryEvictionAndHistoryStaysBounded() {
        let log = ConversationLog()
        let update = UUID()
        log.noteSessionUpdate(event(update))
        for index in 0..<ConversationLog.limit {
            log.noteSent("Request \(index)", endpointID: "mac", targetID: "tmux:build")
        }
        log.noteSessionUpdate(event(update))
        #expect(log.entries.count == ConversationLog.limit)
        #expect(log.entries.allSatisfy { $0.updatePriority == nil })
        for _ in 0..<(ConversationLog.limit + 1) { log.noteSessionUpdate(event()) }
        #expect(log.entries.count == ConversationLog.limit)
        #expect(log.entries.allSatisfy { $0.updatePriority == "info" })
    }

    @Test func anUpdateDoesNotConsumeAnAddressedRequest() {
        let log = ConversationLog()
        let targets = [TargetInfo(id: "tmux:build", kind: "tmux", name: "Build", alive: true)]
        log.noteSent("Build, check it", endpointID: "mac", targetID: "tmux:voice", targets: targets, scope: "live")
        log.noteSessionUpdate(event())
        let reply = ReplyDescriptor(id: UUID(), hostID: "host", targetID: "tmux:build")
        log.noteReply(HostReplyEvent(endpointID: "mac", frame: Frame(timestamp: 2, source: "host",
            payload: .text(TextPayload(text: "Requested answer", reply: reply)))),
            selected: "tmux:voice", scope: "live")
        #expect(log.entries.last?.shownIn == "tmux:voice")
        #expect(log.entries[1].shownIn == nil)
    }

    @Test func missingTargetDoesNotGuessFromTheSessionLabel() {
        let log = ConversationLog()
        log.noteSessionUpdate(event(target: nil))
        #expect(log.entries.isEmpty)
    }
}
