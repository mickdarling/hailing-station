import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Deterministic guard-budget clocks (#208). Production measures each rule's 20 ms budget on `ContinuousClock`
/// and counts an expired budget as a hit; on a loaded runner a preempted match crossed that deadline and turned a
/// benign RightyO delivery into `confirmationRequired`. Tests whose subject is not guard timing bind `frozen`;
/// the fail-closed path is asserted under `expiring()` instead of hoping the scheduler is slow.
extension GuardBudgetClock {
    /// Never advances, so no budget expires: only a real regex match is a hit.
    static let frozen: GuardBudgetClock = {
        let instant = ContinuousClock.now
        return GuardBudgetClock { instant }
    }()

    /// Each reading is an hour after the previous one, so every rule's budget has expired at its first progress
    /// check, however fast the machine is.
    static func expiring() -> GuardBudgetClock {
        final class Readings: Sendable { let count = Mutex(0) }
        let base = ContinuousClock.now
        let readings = Readings()
        return GuardBudgetClock {
            base + .seconds(3600) * readings.count.withLock { count in
                defer { count += 1 }
                return count
            }
        }
    }
}

/// Binds `GuardBudgetClock.frozen` around every test case of a suite (#208).
struct FrozenGuardBudget: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await GuardBudgetClock.$current.withValue(.frozen) { try await function() }
    }
}

extension Trait where Self == FrozenGuardBudget {
    static var frozenGuardBudget: Self { Self() }
}

@Suite struct GuardBudgetClockTests {
    static let benign = "Please summarize our discussion and list the open questions for tomorrow. "
        + String(repeating: "The project notes are in the shared folder. ", count: 40)

    @Test func productionReadsTheContinuousClockWhenNothingIsBound() {
        let before = ContinuousClock.now
        let reading = GuardBudgetClock.current.now()
        let after = ContinuousClock.now
        #expect(before <= reading && reading <= after)
    }

    @Test func expiredBudgetFailsClosedOnABenignLineUnderTheDefaultBudget() throws {
        let guards = try CompiledGuards(DangerousPatternGuard.defaults)
        let names = DangerousPatternGuard.defaults.map(\.name)
        GuardBudgetClock.$current.withValue(.frozen) {
            #expect(guards.matches(in: [Self.benign]).isEmpty)
        }
        // A rule whose scan reaches an ICU progress check after its deadline is a hit; anchored rules that reject the
        // line before the first check finish within budget by construction and are not timing-dependent.
        let expired = GuardBudgetClock.$current.withValue(.expiring()) { guards.matches(in: [Self.benign]) }
        #expect(expired.contains("delete") && expired.contains("credential"))
        #expect(Set(expired).isSubset(of: names))
    }

    @Test func frozenClockStillReportsRealMatches() throws {
        let guards = try CompiledGuards(DangerousPatternGuard.defaults)
        GuardBudgetClock.$current.withValue(.frozen) {
            #expect(guards.matches(in: ["sudo rm -rf /"]) == ["rm -rf", "sudo"])
        }
    }
}

/// The RightyO path keeps failing closed when a guard budget expires (#208); the rest of the suite runs frozen.
extension RightyoInputConsumerTests {
    @Test func suiteRunsUnderTheFrozenGuardClock() {
        #expect(GuardBudgetClock.current.now() == GuardBudgetClock.frozen.now())
    }

    @Test func guardTimeoutStillRefusesARightyoDeliveryAndTargetValidation() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        let attended = try await lateRequest(consumer, role: nil, decisionRole: "unknown")
        await #expect(throws: RightyoInputError.confirmationRequired) {
            try await GuardBudgetClock.$current.withValue(.expiring()) { try await consumer.consume(attended) }
        }
        #expect(await adapter.deliveries.isEmpty)
        #expect(throws: RightyoTargetError.self) {
            try GuardBudgetClock.$current.withValue(.expiring()) {
                try RightyoInputConsumer.validateTarget("tmux:demo")
            }
        }
        try RightyoInputConsumer.validateTarget("tmux:demo")
    }
}
