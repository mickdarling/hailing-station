import Foundation
import Synchronization
import Testing

/// Bounded, deterministic barriers around synthetic admission. No devices, speech or providers are used.
final class RecipientPublicationClock: Sendable {
    private let origin = ContinuousClock.now
    private let remaining = Mutex<Int?>(nil)
    let gate: RecipientPublicationGate
    let executor = RecipientPublicationExecutor()
    init(timeout: DispatchTimeInterval = .seconds(45)) { gate = RecipientPublicationGate(timeout: timeout) }

    // Pruning is followed by the pre-gate lifetime check; pause there, before either authority lock.
    func arm() { remaining.withLock { $0 = 2 } }
    func now() -> ContinuousClock.Instant {
        // A sticky pre-creation instant refuses even late-answer/provider-turn requests after timeout.
        let refused = origin.advanced(by: .seconds(-1))
        guard !gate.timedOut else { return refused }
        let block = remaining.withLock { count in
            guard let old = count else { return false }
            count = old > 1 ? old - 1 : nil
            return old == 1
        }
        if block, !gate.block(onDedicatedQueue: executor.isExecuting) {
            return refused
        }
        return origin
    }

    /// Drain first; only then classify the race, before any authority assertions can run.
    func finish(_ publication: Task<Bool, Never>) async -> Bool? {
        gate.release()
        let accepted = await publication.value
        guard !gate.timedOut else {
            Issue.record(
                "#846: harness gate timed out before the authority change landed; the authority result is inconclusive"
            )
            return nil
        }
        return accepted
    }
}
