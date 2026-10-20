import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #636 slice 7a: a reply from a session other than the selected one, such as one the user addressed by name, shows
/// in the thread the user was in, labelled with that session's listed name. Synthetic frames only.
@MainActor
@Suite struct ConversationReplySourceTests {
    private static let targets = [
        TargetInfo(id: "tmux:scratch", kind: "tmux", name: "Hailing Scratch", alive: true),
        TargetInfo(id: "tmux:deck", kind: "tmux", name: "Deck", alive: true)
    ]

    private func reply(_ text: String, id: UUID = UUID(), from target: String) -> HostReplyEvent {
        let descriptor = ReplyDescriptor(id: id, hostID: "host", targetID: target)
        let frame = Frame(timestamp: 0, source: "host", payload: .text(TextPayload(text: text, reply: descriptor)))
        return HostReplyEvent(endpointID: "mac", frame: frame)
    }

    @Test func aReplyFromAnotherSessionShowsInTheSelectedThreadWithItsName() {
        let log = ConversationLog()
        log.noteSent("Deck, add a slide on pricing", endpointID: "mac", targetID: "tmux:scratch")
        log.noteReply(reply("Added it.", from: "tmux:deck"), selected: "tmux:scratch", targets: Self.targets)
        log.noteReply(reply("Done here too.", from: "tmux:scratch"), selected: "tmux:scratch", targets: Self.targets)
        let thread = log.entries(endpointID: "mac", targetID: "tmux:scratch")
        #expect(thread.map(\.text) == ["Deck, add a slide on pricing", "Added it.", "Done here too."])
        #expect(thread.map(\.source) == [nil, "Deck", nil], "the selected session's own reply needs no label")
        // Deck's own thread still has its reply, which is unlabelled there.
        #expect(log.entries(endpointID: "mac", targetID: "tmux:deck").map(\.text) == ["Added it."])
        #expect(log.entries(endpointID: "other", targetID: "tmux:scratch").isEmpty)
    }

    @Test func anUnlistedSessionIsLabelledByItsIdAndTheLabelIsFixedAtArrival() {
        let log = ConversationLog()
        let id = UUID()
        log.noteReply(reply("First.", id: id, from: "tmux:gone"), selected: "tmux:scratch", targets: Self.targets)
        log.noteReply(reply("First, then more.", id: id, from: "tmux:gone"), selected: "tmux:deck", targets: [])
        let entry = log.entries.first
        #expect(log.entries.count == 1 && entry?.text == "First, then more.")
        #expect(entry?.source == "tmux:gone" && entry?.shownIn == "tmux:scratch")
    }

    @Test func withNoSelectionNothingIsLabelled() {
        let log = ConversationLog()
        log.noteReply(reply("Hello.", from: "tmux:deck"))
        #expect(log.entries.first?.source == nil && log.entries.first?.shownIn == nil)
    }
}

/// The store passes its confirmed selection and the host's listed names to the chat (#636 slice 7a).
extension HostConnectionStoreAmbientBindingTests {
    @Test func aReplyFromAnotherSessionJoinsTheSelectedThreadLabelled() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "receive_replies"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await socket.push(.targets([
            TargetInfo(id: "tmux:a", kind: "tmux", name: "Hailing Scratch", alive: true),
            TargetInfo(id: "tmux:deck", kind: "tmux", name: "Deck", alive: true)
        ]))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.targets.count == 2 } }
        try await select("tmux:a", on: ready)
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac", targetID: "tmux:deck")
        try await socket.push(FrameCoding.encode(Frame(
            timestamp: 2, target: "tmux:deck", source: "mac",
            payload: .text(TextPayload(text: "Added it.", isFinal: true, reply: reply))
        )))
        try await waitUntil { await MainActor.run { !store.conversation.entries.isEmpty } }
        let thread = store.conversation.entries(endpointID: endpoint.id, targetID: "tmux:a")
        #expect(thread.map(\.text) == ["Added it."] && thread.first?.source == "Deck")
        await store.disconnect(endpoint.id)
    }
}
