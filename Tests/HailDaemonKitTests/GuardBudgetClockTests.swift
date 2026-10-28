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

#if os(macOS)
/// Socket callbacks lose the test's task locals. Rebind its guard clock before starting a run,
/// so a semantic fixture cannot become a second refusal through a budget timeout.
struct GuardClockAmbientSink: AmbientAudioSink {
    let router: AmbientRightyoRouter
    private let clock = GuardBudgetClock.current
    func ambientAudio(_ event: AmbientAudioEvent) {
        GuardBudgetClock.$current.withValue(clock) { router.ambientAudio(event) }
    }
    func ambientInputRoute(_ route: String, connection: UUID) {
        GuardBudgetClock.$current.withValue(clock) { router.ambientInputRoute(route, connection: connection) }
    }
    func ambientPrivacy(_ on: Bool, connection: UUID) {
        GuardBudgetClock.$current.withValue(clock) { router.ambientPrivacy(on, connection: connection) }
    }
    func ambientPrivacyPreArm(connection: UUID) {
        GuardBudgetClock.$current.withValue(clock) { router.ambientPrivacyPreArm(connection: connection) }
    }
    func ambientPrivacyPreArmRefused(connection: UUID, reason: String) {
        GuardBudgetClock.$current.withValue(clock) {
            router.ambientPrivacyPreArmRefused(connection: connection, reason: reason)
        }
    }
}

#endif

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

    /// Delivered text keeps the #208 rule: an expired budget is a hit. Target validation (#658) matches fixed host
    /// text without the budget, so an expiring clock refuses only an id a rule really matches.
    @Test func guardTimeoutStillRefusesARightyoDeliveryButNotABenignTarget() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        let attended = try await lateRequest(consumer, role: nil, decisionRole: "unknown")
        #expect(try await !GuardBudgetClock.$current.withValue(.expiring()) { try await consumer.consume(attended) })
        #expect(await adapter.deliveries.isEmpty)
        try GuardBudgetClock.$current.withValue(.expiring()) {
            try RightyoInputConsumer.validateTarget("tmux:demo")
            #expect(throws: RightyoTargetError.guarded(["sudo"])) {
                try RightyoInputConsumer.validateTarget("tmux:sudo")
            }
        }
    }

    @Test func targetBlockMatchingIgnoresTheClockButBudgetedMatchingStillFailsClosed() throws {
        let guards = try CompiledGuards(DangerousPatternGuard.defaults)
        let longest = String(repeating: "a", count: 96)
        GuardBudgetClock.$current.withValue(.expiring()) {
            #expect(DangerousPatternGuard.targetBlockMatches(target: RecipientTestRig.target).isEmpty)
            #expect(DangerousPatternGuard.targetBlockMatches(target: longest).isEmpty)
            #expect(DangerousPatternGuard.targetBlockMatches(target: "tmux:sudo") == ["sudo"])
            #expect(!guards.matches(in: [GuardBudgetClockTests.benign]).isEmpty)
        }
    }

    /// Defence in depth (#658): the longest allowlisted id stays well under the cap; a block over it is a hit.
    @Test func aTargetBlockOverTheByteCapIsAHit() {
        let longest = RightyoInputEvent.replyBlock(target: String(repeating: "a", count: 96))
        #expect(longest.utf8.count <= DangerousPatternGuard.maxTargetBlockBytes)
        #expect(DangerousPatternGuard.targetBlockMatches(target: String(repeating: "a", count: 512))
                == ["target block too long"])
    }
}
