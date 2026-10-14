import Foundation
import Testing
@testable import HailDaemonKit

func observedAwaitDispatch(
    _ rig: ObservedRig, session: ProviderObservedSession,
    input: Task<ProviderInputOutcome, any Error>, completed: ObservedCounter
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while rig.adapter.dispatch.arrivals.count < 1, completed.count < 1, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard rig.adapter.dispatch.arrivals.count < 1 else { return }
    await session.stop()
    await rig.adapter.dispatch.releaseAll()
    let outcome = completed.count >= 1 ? String(describing: await input.result) : "input still pending"
    try #require(false, "held dispatch was never entered: \(outcome)")
}

func observedAwaitStoppedInput(
    _ rig: ObservedRig, session: ProviderObservedSession, completed: ObservedCounter
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while completed.count < 1, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard completed.count < 1 else { return }
    await session.stop()
    await rig.adapter.dispatch.releaseAll()
    try #require(false, "stopped input did not finish after releasing the first held write")
}
