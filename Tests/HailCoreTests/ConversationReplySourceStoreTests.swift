import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// The store passes its confirmed selection and the host's listed names to the chat (#636 slice 7a).
extension HostConnectionStoreAmbientBindingTests {
    @Test func aReplyToAnAddressedSessionJoinsTheSelectedThreadLabelled() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "receive_replies", "send_text"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await socket.push(.targets([
            TargetInfo(id: "tmux:a", kind: "tmux", name: "Hailing Scratch", alive: true),
            TargetInfo(id: "tmux:deck", kind: "tmux", name: "Deck", alive: true)
        ]))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.targets.count == 2 } }
        try await select("tmux:a", on: ready)
        try await store.sendFinalText("Deck, add a slide", host: endpoint.id, targetID: "tmux:a")
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac", targetID: "tmux:deck")
        try await socket.push(FrameCoding.encode(Frame(
            timestamp: 2, target: "tmux:deck", source: "mac",
            payload: .text(TextPayload(text: "Added it.", isFinal: true, reply: reply))
        )))
        try await waitUntil { await MainActor.run { store.conversation.entries.count == 2 } }
        let thread = store.conversation.entries(endpointID: endpoint.id, targetID: "tmux:a")
        #expect(thread.map(\.text) == ["Deck, add a slide", "Added it."] && thread.last?.source == "Deck")
        await store.disconnect(endpoint.id)
    }

    /// Selecting away and back retires the address, as the host retires its reply claim.
    @Test func reselectingRetiresAnAddressedRequest() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "receive_replies", "send_text"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await socket.push(.targets([
            TargetInfo(id: "tmux:a", kind: "tmux", name: "Hailing Scratch", alive: true),
            TargetInfo(id: "tmux:deck", kind: "tmux", name: "Deck", alive: true)
        ]))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.targets.count == 2 } }
        try await select("tmux:a", on: ready)
        try await store.sendFinalText("Deck, add a slide", host: endpoint.id, targetID: "tmux:a")
        try await select("tmux:deck", on: ready)
        try await reselect("tmux:a", on: ready)
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac", targetID: "tmux:deck")
        try await socket.push(FrameCoding.encode(Frame(
            timestamp: 2, target: "tmux:deck", source: "mac",
            payload: .text(TextPayload(text: "Late.", isFinal: true, reply: reply))
        )))
        try await waitUntil { await MainActor.run { store.conversation.entries.count == 2 } }
        let thread = store.conversation.entries(endpointID: endpoint.id, targetID: "tmux:a")
        #expect(thread.map(\.text) == ["Deck, add a slide"])
        await store.disconnect(endpoint.id)
    }

    /// Selects a target this socket has selected before: answers only a ping sent after this selection's own frames, so
    /// an earlier selection's ping is never mistaken for it.
    private func reselect(_ target: String, on ready: ReadyStore) async throws {
        let before = try await ready.socket.sentFrames().count
        let selection = Task { try await ready.store.selectTarget(host: ready.endpoint.id, targetID: target) }
        let socket = ready.socket
        try await waitUntil { try await Self.ping(on: socket, after: before) != nil }
        try await socket.push(.pong(nonce: try #require(try await Self.ping(on: socket, after: before))))
        try await selection.value
    }

    private static func ping(on socket: ScriptedSocket, after count: Int) async throws -> String? {
        for frame in try await socket.sentFrames().dropFirst(count) {
            if case .control(.ping(let nonce)) = frame.payload { return nonce }
        }
        return nil
    }
}
