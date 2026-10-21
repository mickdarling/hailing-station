import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// What slice 7b (#636) turns on with addressed threads, deferred from #666's reviews: a request shows before a reply
/// that comes back while it is still sending, a failed send leaves nothing behind, and a placed reply counts as an
/// arrival in the thread that shows it.
extension HostConnectionStoreAmbientBindingTests {
    @Test func aReplyThatArrivesWhileItsRequestIsStillSendingShowsAfterIt() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "receive_replies", "send_text"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await socket.push(.targets([
            TargetInfo(id: "tmux:a", kind: "tmux", name: "Hailing Scratch", alive: true),
            TargetInfo(id: "tmux:deck", kind: "tmux", name: "Deck", alive: true)
        ]))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.targets.count == 2 } }
        try await select("tmux:a", on: ready)
        await socket.holdSends()
        let sending = Task { try await store.sendFinalText("Deck, add a slide", host: endpoint.id, targetID: "tmux:a") }
        try await waitUntil {
            try await socket.sentFrames().contains { frame in
                if case .text(let text) = frame.payload { return text.text == "Deck, add a slide" }
                return false
            }
        }
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac", targetID: "tmux:deck")
        try await socket.push(FrameCoding.encode(Frame(
            timestamp: 2, target: "tmux:deck", source: "mac",
            payload: .text(TextPayload(text: "Added it.", isFinal: true, reply: reply))
        )))
        try await waitUntil { await MainActor.run { store.conversation.entries.count == 2 } }
        await socket.releaseSends()
        try await sending.value
        let thread = store.conversation.entries(endpointID: endpoint.id, targetID: "tmux:a", addressed: true)
        #expect(thread.map(\.text) == ["Deck, add a slide", "Added it."])
        #expect(thread.last?.source == "Deck")
        await store.disconnect(endpoint.id)
    }

    @Test func aSendThatFailsLeavesNoRequestInTheThread() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "receive_replies"])
        let (store, endpoint) = (ready.store, ready.endpoint)
        try await select("tmux:a", on: ready)
        await #expect(throws: (any Error).self) {
            try await store.sendFinalText("Deck, add a slide", host: endpoint.id, targetID: "tmux:a")
        }
        #expect(store.conversation.entries.isEmpty)
        await store.disconnect(endpoint.id)
    }
}

/// The replies that answer a thread (#636): a placed reply joins its arrival set only with `addressed`.
@MainActor
@Suite struct ConversationThreadReplyIDTests {
    @Test func aPlacedReplyIsAnArrivalInTheThreadThatShowsIt() {
        let log = ConversationLog()
        let endpoint: HostEndpoint.Identifier = "mac-a"
        let targets = [TargetInfo(id: "tmux:a", kind: "tmux", name: "Scratch", alive: true),
                       TargetInfo(id: "tmux:deck", kind: "tmux", name: "Deck", alive: true)]
        log.noteSent("Deck, add a slide", endpointID: endpoint, targetID: "tmux:a", targets: targets, scope: "s")
        let (placed, own, other) = (UUID(), UUID(), UUID())
        log.noteReply(Self.reply(placed, from: "tmux:deck", on: endpoint), selected: "tmux:a", scope: "s")
        log.noteReply(Self.reply(own, from: "tmux:a", on: endpoint), selected: "tmux:a", scope: "s")
        log.noteReply(Self.reply(other, from: "tmux:deck", on: endpoint), selected: "tmux:a", scope: "s")
        let replies = [placed, own, other].map { id in
            ReplyPresentation(id: Self.entryID(id, on: endpoint), endpointID: endpoint, host: "mac",
                              target: id == own ? "tmux:a" : "tmux:deck", transcript: nil)
        }
        let scratch = log.threadReplyIDs(endpointID: endpoint, targetID: "tmux:a", among: replies, addressed: true)
        #expect(scratch == [Self.entryID(placed, on: endpoint), Self.entryID(own, on: endpoint)])
        #expect(log.threadReplyIDs(endpointID: endpoint, targetID: "tmux:a", among: replies)
                == [Self.entryID(own, on: endpoint)])
        #expect(log.threadReplyIDs(endpointID: "mac-b", targetID: "tmux:a", among: replies,
                                   addressed: true).isEmpty)
    }

    @Test func aRetractedRequestLeavesTheThread() {
        let log = ConversationLog()
        let endpoint: HostEndpoint.Identifier = "mac-a"
        let kept = log.noteSent("First", endpointID: endpoint, targetID: "tmux:a")
        let dropped = log.noteSent("Second", endpointID: endpoint, targetID: "tmux:a")
        log.retractSent(dropped)
        log.retractSent(nil)
        #expect(log.entries.map(\.id) == [kept].compactMap { $0 })
    }

    static func reply(_ id: UUID, from target: String, on endpoint: HostEndpoint.Identifier) -> HostReplyEvent {
        HostReplyEvent(endpointID: endpoint, frame: Frame(
            timestamp: 2, target: target, source: "mac",
            payload: .text(TextPayload(text: "Reply", isFinal: true,
                                       reply: ReplyDescriptor(id: id, hostID: "mac", targetID: target)))
        ))
    }

    static func entryID(_ id: UUID, on endpoint: HostEndpoint.Identifier) -> String {
        "\(endpoint)|\(id.uuidString.lowercased())"
    }
}
