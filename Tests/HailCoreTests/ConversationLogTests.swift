import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #288: the station chat keeps what was sent and what Haili replied, in order, per destination.
@MainActor
@Suite struct ConversationLogTests {
    private func replyEvent(
        _ text: String, id: UUID, endpoint: String = "mac", target: String = "tmux:a"
    ) -> HostReplyEvent {
        let reply = ReplyDescriptor(id: id, hostID: "host", targetID: target)
        let frame = Frame(timestamp: 0, source: "host", payload: .text(TextPayload(text: text, reply: reply)))
        return HostReplyEvent(endpointID: endpoint, frame: frame)
    }

    @Test func sentRequestsAndRepliesAppearInOrder() {
        let log = ConversationLog()
        log.noteSent("  What changed?  ", endpointID: "mac", targetID: "tmux:a")
        let reply = UUID()
        log.noteReply(replyEvent("The build passed.", id: reply))
        log.noteSent("Thanks", endpointID: "mac", targetID: "tmux:a")

        let entries = log.entries(endpointID: "mac", targetID: "tmux:a")
        #expect(entries.map(\.speaker) == [.you, .haili, .you])
        #expect(entries.map(\.text) == ["What changed?", "The build passed.", "Thanks"])
        #expect(entries[1].id == "mac|\(reply.uuidString.lowercased())")
    }

    @Test func laterTextForTheSameReplyUpdatesItInPlace() {
        let log = ConversationLog()
        let reply = UUID()
        log.noteReply(replyEvent("Partial", id: reply))
        log.noteSent("Next", endpointID: "mac", targetID: "tmux:a")
        log.noteReply(replyEvent("Partial, then complete.", id: reply))
        #expect(log.entries.map(\.text) == ["Partial, then complete.", "Next"])
    }

    @Test func blankSendsAndNonTextFramesAreIgnored() {
        let log = ConversationLog()
        log.noteSent("   ", endpointID: "mac", targetID: "tmux:a")
        let plain = Frame(timestamp: 0, source: "host", payload: .text(TextPayload(text: "no reply")))
        log.noteReply(HostReplyEvent(endpointID: "mac", frame: plain))
        #expect(log.entries.isEmpty)
    }

    @Test func entriesAreScopedToTheirDestinationAndBounded() {
        let log = ConversationLog()
        log.noteSent("to a", endpointID: "mac", targetID: "tmux:a")
        log.noteSent("to b", endpointID: "mac", targetID: "tmux:b")
        #expect(log.entries(endpointID: "mac", targetID: "tmux:b").map(\.text) == ["to b"])

        for index in 0..<(ConversationLog.limit + 5) {
            log.noteSent("line \(index)", endpointID: "mac", targetID: "tmux:a")
        }
        #expect(log.entries.count == ConversationLog.limit)
        #expect(log.entries.last?.text == "line \(ConversationLog.limit + 4)")
    }
}
