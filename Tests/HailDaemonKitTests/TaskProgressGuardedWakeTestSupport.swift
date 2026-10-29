import Dispatch
import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

final class TaskProgressGuardedWiring: AmbientListenerWiring {
    private struct State { var audience: TaskProgressAmbientAudience?; var media = false }
    private let state = Mutex(State())
    func attach(_ listener: WebSocketListener) {}
    func stop(connection: UUID) {}
    func shutdown() async {}
    func isLatest(stream: UUID, connection: UUID) -> Bool {
        state.withLock { $0.audience?.connection == connection && $0.audience?.stream == stream }
    }
    func activeConnection() -> UUID? { state.withLock { $0.audience?.connection } }
    func mediaMode(connection: UUID) -> Bool { state.withLock { $0.audience?.connection == connection && $0.media } }
    var sessionUpdatesPrivate: Bool { false }
    func withSessionUpdatePermission(connection: UUID, enqueue: @Sendable () -> Bool) -> Bool {
        state.withLock { $0.audience?.connection == connection && !$0.media && enqueue() }
    }
    func taskProgressAudience() -> TaskProgressAmbientAudience? { state.withLock { $0.audience } }
    func withTaskProgressPermission(
        _ expected: TaskProgressAmbientAudience, commit: @Sendable () -> Bool
    ) -> Bool { state.withLock { $0.audience == expected && !$0.media && commit() } }
    func select(connection: UUID) {
        state.withLock { $0.audience = TaskProgressAmbientAudience(connection: connection, stream: UUID()) }
    }
    func disconnect() { state.withLock { $0.audience = nil } }
    func enterMedia() { state.withLock { $0.media = true } }
}

struct TaskProgressGuardedWakeRig {
    let host: HailHost
    let listener: WebSocketListener
    let connection: UUID
    let target: String
    let wiring: TaskProgressGuardedWiring
    let clock: ProgressTestClock
    let finished = AsyncStream<Void>.makeStream()

    static func make(adapter: any Adapter) async throws -> Self {
        let registry = Registry()
        try await registry.register(adapter)
        let target = Registry.id(kind: adapter.kind, name: "a")
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")])
        try policy.allow(target, binding: "binding-a", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "synthetic-host")
        _ = await session.receive(helloFrame(capabilities: [SessionUpdateCard.capability]))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        let wiring = TaskProgressGuardedWiring(), clock = ProgressTestClock()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "synthetic-host", ambient: wiring)
        let peer = WebSocketPeer(id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: session, queue: DispatchQueue(label: "synthetic.guarded.wake"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitReply: { $0(nil) })
        let connection = await session.connectionID, generation = await session.selectionGeneration
        await listener.enableSessionUpdates()
        await listener.installGuardedWakePeer(peer, target: target, connection: connection, generation: generation)
        wiring.select(connection: connection)
        await listener.enableTaskProgress(clock: clock.clock)
        return Self(host: host, listener: listener, connection: connection, target: target,
                    wiring: wiring, clock: clock)
    }

    func start() async throws -> UUID {
        let id = UUID()
        let result = await TaskProgressWakeScope.$didFinishWake.withValue({
            finished.continuation.yield(())
        }, operation: {
            await listener.taskProgress(.init(action: .start, target: target, task: id, seconds: 60))
        })
        try #require(result.task == id && result.nextDueInSeconds == 60)
        return id
    }
}

extension WebSocketListener {
    func installGuardedWakePeer(_ peer: WebSocketPeer, target: String, connection: UUID, generation: UUID) {
        readyResult = .success(0)
        peers[UUID()] = peer
        lastInput.record(.init(connection: connection, generation: generation, at: .now), for: target)
    }
}
