import Foundation
import Synchronization

/// Attempt is conservative: it marks the adapter's admitted authority/handoff check, not provider acceptance.
/// An adapter may perform a side effect and then throw CancellationError; that never permits another prompt.
final class TaskProgressWakeAttempt: Sendable {
    private let attempted = Mutex(false)
    var hasAttempt: Bool { attempted.withLock { $0 } }
    func begin() { attempted.withLock { $0 = true } }

    /// Expiry limits first admission only. Once admitted, later fully guarded adapter checks keep their
    /// existing policy/task boundaries without imposing a new cancellation limit on in-flight work.
    func begin(before lifetime: TaskProgressAdmissionLifetime) -> Bool {
        attempted.withLock { attempted in
            if attempted { return true }
            guard !lifetime.isExpired else { return false }
            attempted = true
            return true
        }
    }
}

/// Immutable enrollment bound and its injected monotonic clock, captured before the listener actor hop.
/// `now` reads time only: no I/O, actor hop or suspension occurs at final admission.
struct TaskProgressAdmissionLifetime: Sendable {
    let expires: ContinuousClock.Instant
    let clock: TaskProgressClock
    var isExpired: Bool { clock.now() >= expires }
}

enum TaskProgressWakeScope {
    @TaskLocal static var beforeHandoff: (@Sendable () throws -> Void)?
    /// Carry the original task closure through registry/adapter suspension. The policy check releases its
    /// lock before the retained task closure takes its own original generation and short admission gates.
    /// Neither check spans adapter I/O. CheckedHandoffDelivering still checks only at its explicit handoff.
    static func deliveryAuthority(
        policy: DeliveryAuthority?, handoff: (@Sendable () throws -> Void)?
    ) -> DeliveryAuthority? {
        guard let handoff else { return policy }
        return DeliveryAuthority {
            try policy?.requireCurrent()
            try handoff()
        }
    }

    /// Deterministic completion evidence for authored concurrency tests; absent in production.
    @TaskLocal static var didFinishWake: (@Sendable () -> Void)?
}

extension WebSocketListener {
    /// Final input admission uses the same retained policy/task/privacy/quiet/ambient boundaries as output.
    /// No await occurs while these gates mark a handoff attempt; their locks never span an adapter operation.
    func taskProgressHandoff(
        for task: TaskProgressTask, authority: TaskProgressPublicationAuthority,
        privacyRevision: UInt64, attempt: TaskProgressWakeAttempt, lifetime: TaskProgressAdmissionLifetime
    ) -> (@Sendable () throws -> Void)? {
        guard !stopped, task.session == authority.generation.target, task.binding == authority.binding,
              let connection = updateAudience(for: task.session).target,
              let audience = ambient?.taskProgressAudience(), audience.connection == connection else { return nil }
        let (fence, hold, ambient) = (sessionUpdateFence, replyHold, self.ambient)
        return {
            let admitted = authority.perform {
                fence.enqueue {
                    let commit: @Sendable () -> Bool = {
                        hold.unlessAnyHeld(expectedRevision: privacyRevision) { attempt.begin(before: lifetime) }
                    }
                    return ambient?.withTaskProgressPermission(audience, commit: commit) ?? false
                }
            }
            guard admitted else { throw CancellationError() }
        }
    }
}

extension TaskProgressWake {
    var statusPrompt: String {
        "Task progress check for enrolled task \(task.id.uuidString). "
            + "Report confirmed progress, remaining work, next step and blockers only. "
            + "Use haild progress report \(task.id.uuidString) --token \(token.uuidString) "
            + "--say <short-update> [--card <details>], or omit --say when unchanged. "
            + "When the task is complete use haild progress finish \(task.id.uuidString) --say <completion>; "
            + "when canceled use haild progress cancel \(task.id.uuidString). "
            + "This grants no recovery, interruption, new work or request renewal."
    }
}
