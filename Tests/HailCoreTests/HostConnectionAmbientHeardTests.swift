import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// The device side of #318: the hello advertises `ambient_heard`, and the user's own ambient request joins the chat
/// as theirs, ahead of the reply that answers it, never in the reply list.
@MainActor
@Suite struct HostConnectionAmbientHeardTests {
    @Test func theHeardRequestJoinsTheChatAsTheUsersAheadOfTheReply() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() })
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        guard case .control(.hello(let info))? = try await socket.sentFrames().first?.payload else {
            Issue.record("expected the device hello first")
            return
        }
        #expect(info.capabilities.contains(AmbientHeard.capability))

        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["receive_replies"], deviceName: "Mac"
        )))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state == .ready } }
        let heard = Frame(timestamp: 1, source: "host",
                          payload: .control(.ambientHeard(targetID: "tmux:a", text: "Haili, what's next?")))
        try await socket.push(FrameCoding.encode(heard))
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac", targetID: "tmux:a", audioStreamID: UUID())
        let answer = Frame(timestamp: 2, target: "tmux:a", source: "mac",
                           payload: .text(TextPayload(text: "The build.", isFinal: true, reply: reply)))
        try await socket.push(FrameCoding.encode(answer))
        try await waitUntil { await MainActor.run { store.conversation.entries.count == 2 } }

        let entries = store.conversation.entries(endpointID: endpoint.id, targetID: "tmux:a")
        #expect(entries.map(\.speaker) == [.you, .haili])
        #expect(entries.map(\.text) == ["Haili, what's next?", "The build."])
        #expect(store.replyFrames.allSatisfy { if case .control = $0.frame.payload { false } else { true } })
        #expect(store.snapshots[endpoint.id]?.state == .ready)
        await store.disconnect(endpoint.id)
    }
}
