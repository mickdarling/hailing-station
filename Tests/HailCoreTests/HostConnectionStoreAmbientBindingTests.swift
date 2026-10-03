import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// The store hands out ambient bindings only for the target the connection will actually address (#203, #218).
@MainActor
@Suite struct HostConnectionStoreAmbientBindingTests {
    @Test func noBindingWithoutStreamAudioSoTheToggleStaysHidden() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target"])
        let (store, endpoint) = (ready.store, ready.endpoint)
        try await select("tmux:a", on: ready)
        #expect(store.ambientBinding(host: endpoint.id, targetID: "tmux:a") == nil)
        await #expect(throws: HostConnectionFailure.notReady) {
            try await store.sendAudio(ambientSegment(), to: AmbientAudioBinding(
                hostID: endpoint.id, targetID: "tmux:a", connectionGeneration: UUID(), selection: 0
            ))
        }
        await store.disconnect(endpoint.id)
    }

    @Test func anyTargetSelectionInvalidatesTheBinding() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await select("tmux:a", on: ready)
        let before = try #require(store.ambientBinding(host: endpoint.id, targetID: "tmux:a"))
        let selection = Task { try await store.selectTarget(host: endpoint.id, targetID: "tmux:a") }
        try await waitUntil {
            await MainActor.run { store.ambientBinding(host: endpoint.id, targetID: "tmux:a") != before }
        }
        await #expect(throws: HostConnectionFailure.notReady) {
            try await store.sendAudio(ambientSegment(), to: before)
        }
        await store.disconnect(endpoint.id)
        _ = await selection.result
        #expect(try await audioFrames(socket).isEmpty)
        #expect(store.ambientBinding(host: endpoint.id, targetID: "tmux:a") == nil)
    }

    /// #218: before any confirmed selection the connection has no target, so there is nothing to bind.
    @Test func noBindingBeforeATargetIsSelected() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        #expect(ready.store.ambientBinding(host: ready.endpoint.id, targetID: "tmux:a") == nil)
        await ready.store.disconnect(ready.endpoint.id)
    }

    /// #218: a binding names exactly the target the connection addresses; a forged one for another target sends
    /// nothing, and the confirmed target's binding streams to that target.
    @Test func aBindingForAnUnselectedTargetIsRefused() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await select("tmux:a", on: ready)
        #expect(store.ambientBinding(host: endpoint.id, targetID: "tmux:b") == nil)
        let selected = try #require(store.ambientBinding(host: endpoint.id, targetID: "tmux:a"))
        let forged = AmbientAudioBinding(
            hostID: endpoint.id, targetID: "tmux:b",
            connectionGeneration: selected.connectionGeneration, selection: selected.selection
        )
        await #expect(throws: HostConnectionFailure.notReady) {
            try await store.sendAudio(ambientSegment(), to: forged)
        }
        #expect(try await audioFrames(socket).isEmpty)

        try await store.sendAudio(ambientSegment(), to: selected)
        #expect(try await audioFrames(socket).map(\.target) == ["tmux:a"])
        await store.disconnect(endpoint.id)
    }

    /// #218: a failed selection leaves no target to bind, even the previously confirmed one.
    @Test func aFailedSelectionLeavesNoBinding() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint) = (ready.store, ready.endpoint)
        try await select("tmux:a", on: ready)
        let failing = Task { try await store.selectTarget(host: endpoint.id, targetID: "tmux:b") }
        _ = try await nextPing(on: ready.socket, after: "tmux:b")
        failing.cancel()
        _ = await failing.result
        #expect(store.ambientBinding(host: endpoint.id, targetID: "tmux:a") == nil)
        #expect(store.ambientBinding(host: endpoint.id, targetID: "tmux:b") == nil)
        await store.disconnect(endpoint.id)
    }

    struct ReadyStore {
        let store: HostConnectionStore
        let endpoint: HostEndpoint
        let socket: ScriptedSocket
    }

    private func select(_ target: String, on ready: ReadyStore) async throws {
        let selection = Task { try await ready.store.selectTarget(host: ready.endpoint.id, targetID: target) }
        try await ready.socket.push(.pong(nonce: try await nextPing(on: ready.socket, after: target)))
        try await selection.value
    }

    private func nextPing(on socket: ScriptedSocket, after target: String) async throws -> String {
        try await waitUntil { try await Self.ping(on: socket, after: target) != nil }
        return try #require(try await Self.ping(on: socket, after: target))
    }

    private static func ping(on socket: ScriptedSocket, after target: String) async throws -> String? {
        let select = ControlPayload.select(targetID: target)
        let frames = try await socket.sentFrames()
        guard let index = frames.lastIndex(where: { $0.payload == .control(select) }) else { return nil }
        for frame in frames[index...] {
            if case .control(.ping(let nonce)) = frame.payload { return nonce }
        }
        return nil
    }

    private func readyStore(capabilities: [String]) async throws -> ReadyStore {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() })
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: capabilities, deviceName: "Mac"
        )))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state == .ready } }
        return ReadyStore(store: store, endpoint: endpoint, socket: socket)
    }
}
