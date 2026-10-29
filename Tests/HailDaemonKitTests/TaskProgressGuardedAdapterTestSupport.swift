import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Ignores task cancellation until explicit release, like an adapter waiting on noncancellable external I/O.
/// No callback runs while its short lock is held. The tests retire authority before opening this barrier.
final class TaskProgressAdapterBarrier: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let open = state.withLock { value in
                if value.open { return true }
                value.waiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }
    func resume() {
        let waiters = state.withLock { value in
            value.open = true
            defer { value.waiters.removeAll() }
            return value.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Contract-valid synthetic guarded adapter: waits before its final check, never between that check and acceptance.
actor TaskProgressGuardedAdapter: Adapter {
    nonisolated let kind = "guardedwake"
    nonisolated let arrived = AsyncStream<Void>.makeStream()
    nonisolated let barrier = TaskProgressAdapterBarrier()
    private(set) var accepted: [String] = []
    private(set) var checks = 0
    private var cancelAfterAcceptance = false

    func listTargets() async throws -> [AdapterTarget] { [.init(name: "a", binding: "binding-a")] }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        Issue.record("guarded task dispatch must not fall back to an unguarded adapter call")
    }
    func deliver(_ text: String, to target: String, binding: String?, authority: DeliveryAuthority) async throws {
        arrived.continuation.yield(())
        await barrier.wait()
        checks += 1
        // A new scope at the sink cannot replace the original task proof captured by the host.
        try TaskProgressWakeScope.$beforeHandoff.withValue({}, operation: { try authority.requireCurrent() })
        accepted.append(text)
        if cancelAfterAcceptance { throw CancellationError() }
    }
    func failAfterAcceptance() { cancelAfterAcceptance = true }
    nonisolated func resume() { barrier.resume() }
}

/// The default guarded overload checks once before entering this explicitly unguarded in-flight operation.
actor TaskProgressCheckedAdapter: CheckedHandoffDelivering {
    nonisolated let kind = "checkedwake"
    nonisolated let arrived = AsyncStream<Void>.makeStream()
    nonisolated let barrier = TaskProgressAdapterBarrier()
    private(set) var accepted: [String] = []
    func listTargets() async throws -> [AdapterTarget] { [.init(name: "a", binding: "binding-a")] }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        arrived.continuation.yield(())
        await barrier.wait()
        accepted.append(text)
    }
    nonisolated func resume() { barrier.resume() }
}
