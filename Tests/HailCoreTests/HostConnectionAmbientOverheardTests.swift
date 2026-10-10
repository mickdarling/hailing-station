import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// The device side of #398: the hello advertises `ambient_overheard`; the chosen scope is sent only to a host that
/// advertised it, and again each time a connection reaches ready; overheard turns join the chat greyed.
@MainActor
@Suite struct HostConnectionAmbientOverheardTests {
    struct Connected {
        let store: HostConnectionStore, socket: ScriptedSocket, endpoint: HostEndpoint
    }

    private func connect(hostCapabilities: [String], scope: String? = nil) async throws -> Connected {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() })
        if let scope { store.setOverheardScope(scope) }
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        guard case .control(.hello(let info))? = try await socket.sentFrames().first?.payload else {
            Issue.record("expected the device hello first")
            return Connected(store: store, socket: socket, endpoint: endpoint)
        }
        #expect(info.capabilities.contains(AmbientOverheard.capability))
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: hostCapabilities, deviceName: "Mac"
        )))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state == .ready } }
        return Connected(store: store, socket: socket, endpoint: endpoint)
    }

    private func scopesSent(_ socket: ScriptedSocket) async throws -> [String] {
        try await socket.sentFrames().compactMap { frame in
            if case .control(.overheardScope(let scope)) = frame.payload { scope } else { nil }
        }
    }

    @Test func aScopeChosenBeforeConnectingIsSentOnceTheCapableHostIsReady() async throws {
        let connected = try await connect(
            hostCapabilities: ["receive_replies", AmbientOverheard.capability], scope: "owner"
        )
        let (store, socket, endpoint) = (connected.store, connected.socket, connected.endpoint)
        try await waitUntil { try await scopesSent(socket) == ["owner"] }
        store.setOverheardScope("everyone")
        try await waitUntil { try await scopesSent(socket) == ["owner", "everyone"] }
        store.setOverheardScope("everyone") // Unchanged: nothing more is sent.
        store.setOverheardScope("all") // Not a scope: ignored.
        #expect(store.overheardScope == "everyone")
        await store.disconnect(endpoint.id)
        let sent = try await scopesSent(socket)
        #expect(sent == ["owner", "everyone"])
    }

    @Test func aHostWithoutTheCapabilityIsNeverSentAScope() async throws {
        let connected = try await connect(hostCapabilities: ["receive_replies"], scope: "everyone")
        let (store, socket, endpoint) = (connected.store, connected.socket, connected.endpoint)
        store.setOverheardScope("owner")
        try await Task.sleep(for: .milliseconds(50))
        let none = try await scopesSent(socket)
        #expect(none.isEmpty)
        #expect(store.snapshots[endpoint.id]?.state == .ready)
        await store.disconnect(endpoint.id)
    }

    @Test func overheardTurnsJoinTheChatGreyedWithTheirSpeaker() async throws {
        let connected = try await connect(
            hostCapabilities: ["receive_replies", AmbientOverheard.capability]
        )
        let (store, socket, endpoint) = (connected.store, connected.socket, connected.endpoint)
        for (text, speaker) in [("Pass the salt.", "owner"), ("Sounds good.", "other")] {
            let frame = Frame(timestamp: 1, source: "host", payload: .control(.ambientOverheard(
                targetID: "tmux:a", text: text, speaker: speaker
            )))
            try await socket.push(FrameCoding.encode(frame))
        }
        try await waitUntil { await MainActor.run { store.conversation.entries.count == 2 } }
        let entries = store.conversation.entries(endpointID: endpoint.id, targetID: "tmux:a")
        #expect(entries.map(\.speaker) == [.you, .someone])
        #expect(entries.allSatisfy { $0.overheard })
        #expect(store.replyFrames.isEmpty)
        #expect(store.snapshots[endpoint.id]?.state == .ready)
        await store.disconnect(endpoint.id)
    }
}
