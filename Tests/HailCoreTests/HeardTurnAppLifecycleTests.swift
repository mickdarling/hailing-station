import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Correlation survives selection changes, but never a connection change (#923).
@MainActor
@Suite struct HeardTurnAppLifecycleTests {
    @Test(arguments: ["disconnect", "reconnect", "replace", "remove"])
    func connectionChangesClearCorrelationWithoutRewritingHistory(change: String) async throws {
        let endpoint = try endpoint()
        let original = ScriptedSocket(), replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(original), for: endpoint.url)
        await connector.enqueue(.socket(replacement), for: endpoint.url)
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() },
                                        sleep: { _ in }, jitter: { 0 })
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await finishHello(original, store: store, endpoint: endpoint)
        let ready = HostConnectionStoreAmbientBindingTests.ReadyStore(
            store: store, endpoint: endpoint, socket: original
        )
        let turn = UUID()
        try await hear(turn, on: ready)
        let generation = store.snapshots[endpoint.id]?.connectionGeneration
        switch change {
        case "reconnect": await original.fail()
        case "replace":
            try await store.upsert(HostEndpoint(id: endpoint.id, name: "synthetic replacement", url: endpoint.url))
            await store.connect(endpoint.id)
        case "remove":
            await store.remove(endpoint.id)
            #expect(store.conversation.entries.first?.heardTurn == nil)
            await store.upsert(endpoint)
            await store.connect(endpoint.id)
        default:
            await store.disconnect(endpoint.id)
            #expect(store.conversation.entries.first?.heardTurn == nil)
            await store.connect(endpoint.id)
        }
        try await finishHello(replacement, store: store, endpoint: endpoint)
        #expect(store.snapshots[endpoint.id]?.connectionGeneration != generation)
        #expect(store.conversation.entries.first?.heardTurn == nil)
        let next = ReadyHeardStore(store: store, endpoint: endpoint, socket: replacement)
        try await hear(UUID(), on: next)
        try await refuse(turn, on: next)
        #expect(store.conversation.entries.map(\.notSent) == [false, false, false])
        #expect(store.conversation.entries.last?.notice == true)
        await store.disconnect(endpoint.id)
    }

    @Test func anotherConnectionCannotRefuseTheFirstConnectionsTurn() async throws {
        let first = try await readyHeardStore()
        let other = try endpoint("synthetic-other", "ws://127.0.0.1:8766")
        let turn = UUID()
        try await hear(turn, on: first)
        // An event from another endpoint enters the same store, as its separate connection's observer would.
        #expect(first.store.receiveAmbientNotice(HostReplyEvent(endpointID: other.id, frame: Frame(
            timestamp: 1, source: "host", payload: .control(.error(
                code: .voiceRouteRefused, message: "synthetic refusal", turn: turn
            ))
        ))))
        #expect(first.store.conversation.entries.first?.notSent == false)
        #expect(first.store.conversation.entries.first?.heardTurn == turn)
        #expect(first.store.conversation.entries.last?.endpointID == other.id)
        try await refuse(turn, on: first)
        #expect(first.store.conversation.entries.first?.notSent == true)
        await first.store.disconnect(first.endpoint.id)
    }

    @Test func selectionChangeStillMarksTheOriginalHeardEntry() async throws {
        let ready = try await readyHeardStore()
        let turn = UUID()
        try await hear(turn, on: ready)
        try await HostConnectionStoreAmbientBindingTests().select("tmux:b", on: ready)
        try await refuse(turn, on: ready)
        #expect(ready.store.conversation.entries.map(\.targetID) == ["tmux:a", "tmux:b"])
        #expect(ready.store.conversation.entries.map(\.notSent) == [true, false])
        await ready.store.disconnect(ready.endpoint.id)
    }

    private func finishHello(
        _ socket: ScriptedSocket, store: HostConnectionStore, endpoint: HostEndpoint
    ) async throws {
        try await waitUntil { try await socket.sentFrames().count == 1 }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["ping", "select_target"], deviceName: "Mac"
        )))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state == .ready } }
    }
}
