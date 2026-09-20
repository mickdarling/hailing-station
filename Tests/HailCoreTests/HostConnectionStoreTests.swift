import Foundation
import HailCore
import HailProtocol
import Testing

@MainActor
@Suite struct HostConnectionStoreTests {
    @Test func twoHostsConnectAndDeletingOneLeavesTheOtherReady() async throws {
        let first = try endpoint("mac-one", "ws://127.0.0.1:8765")
        let second = try endpoint("mac-two", "ws://127.0.0.1:8766")
        let firstSocket = ScriptedSocket()
        let secondSocket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(firstSocket), for: first.url)
        await connector.enqueue(.socket(secondSocket), for: second.url)
        let store = HostConnectionStore(connector: connector, jitter: { 0.5 })
        await store.upsert(first)
        await store.upsert(second)

        await store.connect(first.id)
        await store.connect(second.id)
        try await waitUntil {
            let firstCount = try await firstSocket.sentFrames().count
            let secondCount = try await secondSocket.sentFrames().count
            return firstCount == 1 && secondCount == 1
        }
        try await firstSocket.push(hostHello())
        try await secondSocket.push(hostHello())
        try await waitUntil {
            await MainActor.run {
                store.snapshots[first.id]?.state == .ready && store.snapshots[second.id]?.state == .ready
            }
        }

        let firstTargets = [TargetInfo(id: "tmux:one", kind: "tmux", name: "one", alive: true)]
        let secondTargets = [TargetInfo(id: "tmux:two", kind: "tmux", name: "two", alive: true)]
        try await firstSocket.push(.targets(firstTargets))
        try await secondSocket.push(.targets(secondTargets))
        try await waitUntil {
            await MainActor.run {
                store.snapshots[first.id]?.targets == firstTargets
                    && store.snapshots[second.id]?.targets == secondTargets
            }
        }
        await store.remove(first.id)
        #expect(store.snapshots[first.id] == nil)
        #expect(store.snapshots[second.id]?.state == .ready)
        #expect(store.snapshots[second.id]?.targets == secondTargets)
        await store.disconnect(second.id)
    }

    @Test func editedEndpointRejectsStaleCallbacksFromTheReplacedSocket() async throws {
        let original = try endpoint("stable-id", "ws://127.0.0.1:8765")
        let replacement = try HostEndpoint(id: original.id, name: "renamed", url: #require(URL(string: "ws://127.0.0.1:8766")))
        let oldSocket = ScriptedSocket(finishReceiveOnClose: false)
        let newSocket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(oldSocket), for: original.url)
        await connector.enqueue(.socket(newSocket), for: replacement.url)
        let store = HostConnectionStore(connector: connector, jitter: { 0.5 })

        await store.upsert(original)
        await store.connect(original.id)
        try await waitUntil { try await oldSocket.sentFrames().count == 1 }
        await store.upsert(replacement)
        await store.connect(replacement.id)
        try await waitUntil { try await newSocket.sentFrames().count == 1 }
        try await newSocket.push(hostHello())
        try await waitUntil { await MainActor.run { store.snapshots[replacement.id]?.state == .ready } }
        try await oldSocket.push(.error(code: .malformed, message: "stale"))
        try await Task.sleep(for: .milliseconds(20))

        #expect(store.snapshots[replacement.id]?.endpoint == replacement)
        #expect(store.snapshots[replacement.id]?.state == .ready)
        await store.disconnect(replacement.id)
    }

    @Test func foregroundHealthCheckDoesNotCreateDuplicateSockets() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        let deadline = SleepGate()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let store = HostConnectionStore(
            connector: connector,
            deadlineSleep: { try await deadline.sleep($0) }
        )
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        try await socket.push(hostHello())
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state == .ready } }
        try await waitUntil { try await socket.sentFrames().count == 3 }
        let before = try await socket.sentFrames().count
        await store.sceneBecameActive()
        try await waitUntil { try await socket.sentFrames().count == before + 1 }
        #expect(await connector.openCount(for: endpoint.url) == 1)
        let frames = try await socket.sentFrames()
        guard case .control(.ping(let nonce)) = frames.last?.payload else {
            Issue.record("foreground health check did not send ping")
            return
        }
        try await socket.push(.pong(nonce: nonce))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.lastPingMilliseconds != nil } }
        await deadline.fire()
        await store.disconnect(endpoint.id)
    }

    @Test func missingForegroundPongReplacesTheSocketImmediately() async throws {
        let endpoint = try endpoint()
        let original = ScriptedSocket()
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        let deadline = SleepGate()
        await connector.enqueue(.socket(original), for: endpoint.url)
        await connector.enqueue(.socket(replacement), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            deadlineSleep: { try await deadline.sleep($0) }
        )

        await connection.connect()
        try await waitUntil { try await original.sentFrames().count == 1 }
        try await original.push(hostHello())
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        await connection.foregrounded()
        try await waitUntil { await deadline.isWaiting() }
        await deadline.fire()
        try await waitUntil { try await replacement.sentFrames().count == 1 }

        #expect(await connector.openCount(for: endpoint.url) == 2)
        #expect(await connection.currentSnapshot().state == .negotiating)
        await connection.disconnect()
    }
}
