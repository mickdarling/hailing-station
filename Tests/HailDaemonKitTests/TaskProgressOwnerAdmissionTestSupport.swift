import Foundation
import Synchronization
@testable import HailDaemonKit

final class OwnerTestAdmission: TaskProgressOwnerAdmission {
    let allowed: Bool
    private let entered = Mutex(false)
    var isInside: Bool { entered.withLock { $0 } }
    init(allowed: Bool) { self.allowed = allowed }
    func perform(_ commit: () -> TaskProgressControlResult) -> TaskProgressControlResult {
        guard allowed else { return .noTask }
        entered.withLock { $0 = true }
        defer { entered.withLock { $0 = false } }
        return commit()
    }
}

/// Explicit release ignores cancellation so a retired owner cannot escape the held admission unnoticed.
final class OwnerAdmissionTestBarrier: Sendable {
    private struct State {
        var waiting: CheckedContinuation<Void, Never>?
        var released = false
    }
    private let state = Mutex(State())
    let entered = AsyncStream<UUID>.makeStream()
    func hold(_ task: TaskProgressTask) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let held = state.withLock { state in
                guard !state.released else { return false }
                state.waiting = continuation
                return true
            }
            if held { entered.continuation.yield(task.id) } else { continuation.resume() }
        }
    }
    func release() {
        let waiting = state.withLock { state in
            state.released = true
            let waiting = state.waiting
            state.waiting = nil
            return waiting
        }
        waiting?.resume()
    }
}
