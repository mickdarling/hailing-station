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
    @TaskLocal static var retained: RetainedDeliveryStages?

    /// Existing adapters retain a committing, lock-only handoff check backed by composed admission.
    /// No check holds a gate through asynchronous adapter completion.
    static func checkedHandoff(_ authority: DeliveryAuthority) -> DeliveryAuthority {
        DeliveryAuthority { try authority.admit {} }
    }

    /// Deterministic completion evidence for authored concurrency tests; absent in production.
    @TaskLocal static var didFinishWake: (@Sendable () -> Void)?
}

/// The host supplies target policy once. Contributors retain their original remaining stages.
struct RetainedDeliveryStages: Sendable {
    var generation: TargetPolicyGeneration?
    var gates: [DeliveryAdmission.Stage: DeliveryAdmission.Gate] = [:]

    /// Bridge synchronous Boolean gates without losing a thrown continuation result. The gate callbacks
    /// are nonescaping and must finish on this stack before the operation reference is released.
    private final class Invocation: @unchecked Sendable {
        let operation: () throws -> Void
        var result: Result<Void, any Error>?
        init(_ operation: @escaping () throws -> Void) { self.operation = operation }
        func run() -> Bool { result = Result(catching: operation); return true }
    }

    static func gate(
        _ perform: @escaping @Sendable (_ operation: @Sendable () -> Bool) -> Bool,
        refusal: @escaping @Sendable () throws -> Void = { throw CancellationError() }
    ) -> DeliveryAdmission.Gate {
        let run: @Sendable (() throws -> Void) throws -> Void = { operation in
            try withoutActuallyEscaping(operation) { operation in
                let invocation = Invocation(operation)
                guard perform({ invocation.run() }) else { return try refusal() }
                guard let result = invocation.result else { throw DeliveryAdmissionError.invalidGate }
                try result.get()
            }
        }
        return DeliveryAdmission.Gate(validate: { try run {} }, perform: run)
    }

    static func requireHeld(_ held: HeldSendScope?) throws {
        guard let held else { return }
        guard held.policyCurrent() else { throw HeldAuthorityError.policyChanged }
        guard held.selected() else { throw HeldAuthorityError.selectionChanged }
        guard held.allowed() else { throw HostError.denied(.lockdown) }
        guard held.noticeCurrent() else { throw HeldAuthorityError.noticeExpired }
    }

    static func refusal(target: String) -> @Sendable () throws -> Void {
        return {
            throw HostError.denied(.notAllowed(target))
        }
    }

    func composed(
        policy: TargetPolicyGeneration, handoff: (@Sendable () throws -> Void)? = nil,
        held: HeldSendScope? = nil
    ) -> DeliveryAuthority {
        var stages = gates
        let matches = generation.map { $0.isSameGeneration(as: policy) } ?? true
        let heldMatches = held.map { $0.entry.policy.isSameGeneration(as: policy) } ?? true
        let policyGate = Self.gate({ operation in
            guard matches && heldMatches else { return false }
            return policy.performIfCurrent(operation) == true
        }, refusal: { throw HostError.denied(.notAllowed(policy.target)) })
        let evaluate: @Sendable (() throws -> Void) throws -> Void = { operation in
            do {
                try policyGate.perform {
                    try Self.requireHeld(held)
                    try operation()
                }
            } catch {
                // Re-evaluate refusal precedence only after every nested gate has released.
                if case HostError.denied(.notAllowed) = error { try Self.requireHeld(held) }
                throw error
            }
        }
        stages[.targetPolicy] = DeliveryAdmission.Gate(validate: { try evaluate {} }, perform: evaluate)
        let decision = stages[.attemptCancellation]
        stages[.attemptCancellation] = DeliveryAdmission.Gate(validate: {
            try decision?.validate()
        }, perform: { operation in
            if let decision {
                try decision.perform { try handoff?(); try operation() }
            } else {
                try handoff?()
                try operation()
            }
        })
        return DeliveryAuthority(admission: DeliveryAdmission(gates: stages))
    }
}

extension WebSocketListener {
    /// Compatibility entry point for retained handoff checks.
    func taskProgressHandoff(
        for task: TaskProgressTask, authority: TaskProgressPublicationAuthority,
        privacyRevision: UInt64, attempt: TaskProgressWakeAttempt, lifetime: TaskProgressAdmissionLifetime
    ) -> (@Sendable () throws -> Void)? {
        guard let retained = taskProgressDeliveryStages(for: task, authority: authority,
            privacyRevision: privacyRevision, attempt: attempt, lifetime: lifetime) else { return nil }
        let composed = retained.composed(policy: authority.generation)
        return { try composed.admit {} }
    }

    /// Target policy is supplied by HailHost; this contributor never reacquires that generation's lock.
    func taskProgressDeliveryStages(
        for task: TaskProgressTask, authority: TaskProgressPublicationAuthority,
        privacyRevision: UInt64, attempt: TaskProgressWakeAttempt, lifetime: TaskProgressAdmissionLifetime
    ) -> RetainedDeliveryStages? {
        guard !stopped, task.session == authority.generation.target, task.binding == authority.binding,
              let connection = updateAudience(for: task.session).target,
              let audience = ambient?.taskProgressAudience(), audience.connection == connection,
              let peer = peers.values.first(where: { $0.session.connectionID == connection }),
              let permit = peer.replyTransport.issuePermit() else { return nil }
        let (fence, hold, ambient) = (sessionUpdateFence, replyHold, self.ambient)
        var retained = RetainedDeliveryStages(generation: authority.generation)
        if let taskFence = authority.taskFence {
            retained.gates[.taskOutputFence] = RetainedDeliveryStages.gate { taskFence.perform($0) }
        }
        retained.gates[.sessionUpdateFence] = RetainedDeliveryStages.gate { fence.enqueue($0) }
        retained.gates[.ambientRouter] = RetainedDeliveryStages.gate { operation in
            ambient?.withTaskProgressPermission(audience, commit: operation) ?? false
        }
        retained.gates[.privacyHold] = RetainedDeliveryStages.gate {
            hold.unlessAnyHeld(expectedRevision: privacyRevision, $0)
        }
        retained.gates[.peerLifecycle] = RetainedDeliveryStages.gate { permit.performIfCurrent($0) == true }
        retained.gates[.attemptCancellation] = DeliveryAdmission.Gate(validate: {
            guard attempt.hasAttempt || !lifetime.isExpired else { throw CancellationError() }
        }, perform: { operation in
            guard attempt.begin(before: lifetime) else { throw CancellationError() }
            try operation()
        })
        return retained
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
