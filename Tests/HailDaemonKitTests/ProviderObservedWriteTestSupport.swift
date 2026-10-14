import Foundation
import Testing
@testable import HailDaemonKit

func observedAwaitDispatch(
    _ rig: ObservedRig, input: Task<ProviderInputOutcome, any Error>, completed: ObservedCounter
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while rig.adapter.dispatch.arrivals.count < 1, completed.count < 1, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard rig.adapter.dispatch.arrivals.count < 1 else { return }
    let outcome = completed.count >= 1 ? String(describing: await input.result) : "input still pending"
    try #require(Bool(false), "held dispatch was never entered: \(outcome)")
}

func observedAwaitStoppedInput(_ completed: ObservedCounter) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while completed.count < 1, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard completed.count < 1 else { return }
    try #require(Bool(false), "stopped input did not finish after releasing the first held write")
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

@Suite(.frozenGuardBudget) struct ProviderObservedWriteFixtureTests {
    @Test func cancellingAWaitReleasesTheNoncooperativeWriteBeforeScopeJoin() async throws {
        let rig = try await ObservedRig.make()
        await rig.adapter.configure(holdDispatch: true)
        await rig.adapter.setEmission([])
        let scope = Task {
            try await rig.host.withObservedSession(target: ObservedRig.target,
                                                   configuration: rig.configuration()) { session in
                try await observedWriteFailureCleanup(rig, session: session) {
                    let input = Task { try await session.submit("invented first", utteranceID: UUID()) }
                    await rig.adapter.dispatch.arrivals.wait()
                    try await observedAwaitStoppedInput(ObservedCounter())
                    _ = try await input.value
                }
            }
        }
        await rig.adapter.dispatch.arrivals.wait()
        scope.cancel()
        await #expect(throws: CancellationError.self) { try await scope.value }
        #expect(rig.adapter.cancellations.count == 1)
        #expect(await rig.adapter.delivered.count == 1)
    }
}
