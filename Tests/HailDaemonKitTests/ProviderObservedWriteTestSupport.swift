import Foundation
import Testing
@testable import HailDaemonKit

/// Waits until the held dispatch is entered or the input finishes, whichever happens first. There is no wall-clock
/// deadline: on a loaded parallel-lane runner the input task was once not scheduled for 5 s, and a polled deadline
/// then failed with "input still pending" although nothing was wrong. A real hang is bounded by the test's time
/// limit and `scripts/verify.sh`'s stall detector instead.
func observedAwaitDispatch(
    _ rig: ObservedRig, input: Task<ProviderInputOutcome, any Error>, completed: ObservedCounter
) async throws {
    let progress = ObservedCounter()
    // Unstructured, because `ObservedCounter.wait` cannot be cancelled: the waiter that loses the race ends when
    // its counter moves later in the scenario (or, if dispatch is never entered, with the failing test process).
    Task { await rig.adapter.dispatch.arrivals.wait(for: 1); progress.increment() }
    Task { await completed.wait(for: 1); progress.increment() }
    await progress.wait(for: 1)
    guard rig.adapter.dispatch.arrivals.count < 1 else { return }
    let outcome = String(describing: await input.result)
    try #require(Bool(false), "held dispatch was never entered: \(outcome)")
}

/// Waits for the stopped input to finish after its held write is released; no wall-clock deadline, as above.
func observedAwaitStoppedInput(_ completed: ObservedCounter) async {
    await completed.wait(for: 1)
}

func observedWriteFailureCleanup(
    _ rig: ObservedRig, session: ProviderObservedSession, operation: () async throws -> Void
) async throws {
    do { try await operation() } catch {
        await session.stop()
        await rig.adapter.dispatch.releaseAll()
        throw error
    }
}
