import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

extension GuardBudgetClock {
    /// One simulated pause after each clock's first reading, then stationary. No real sleeps or CPU work.
    static func stepped(wall: Duration = .zero, cpu: Duration? = .zero) -> GuardBudgetClock {
        let base = ContinuousClock.now
        let wallRead = Mutex(false)
        let cpuRead = Mutex(false)
        return GuardBudgetClock(now: {
            let first = wallRead.withLock { read in defer { read = true }; return !read }
            return first ? base : base + wall
        }, cpuNow: {
            let first = cpuRead.withLock { read in defer { read = true }; return !read }
            return first ? .zero : cpu
        })
    }
}

extension GuardBudgetClockTests {
    @Test func productionReadsThreadCPUTime() throws {
        let before = try #require(GuardBudgetClock.threadCPUTime())
        let reading = try #require(GuardBudgetClock.current.cpuNow())
        let after = try #require(GuardBudgetClock.threadCPUTime())
        #expect(before <= reading && reading <= after)
    }

    @Test(arguments: [Duration.milliseconds(20), .milliseconds(21)])
    func CPUOverrunIsATimeout(cpu: Duration) throws {
        let guards = try CompiledGuards([GuardPattern(name: "rule", regex: "never")])
        let hits = GuardBudgetClock.$current.withValue(.stepped(cpu: cpu)) { guards.hits(in: [Self.benign]) }
        #expect(hits == [GuardHit(name: "rule", outcome: .timeout)])
    }

    @Test(arguments: [Duration.milliseconds(50), .milliseconds(999), .seconds(1), .seconds(2)])
    func schedulerPauseUsesTheWallCapRatherThanTheCPUBudget(wall: Duration) throws {
        let guards = try CompiledGuards([GuardPattern(name: "rule", regex: "never")])
        let hits = GuardBudgetClock.$current.withValue(.stepped(wall: wall, cpu: .milliseconds(1))) {
            guards.hits(in: [Self.benign])
        }
        #expect(hits == (wall < CompiledGuards.wallClockCap ? [] : [GuardHit(name: "rule", outcome: .timeout)]))
    }

    @Test(arguments: [true, false])
    func aPathologicalScanTimesOutAfterEntry(onCPUClock: Bool) throws {
        let base = ContinuousClock.now
        let wallReads = Mutex(0)
        let cpuReads = Mutex(0)
        let clock = GuardBudgetClock(now: {
            let count = wallReads.withLock { count in defer { count += 1 }; return count }
            return base + (!onCPUClock && count >= 2 ? .seconds(1) : .zero)
        }, cpuNow: {
            let count = cpuReads.withLock { count in defer { count += 1 }; return count }
            return onCPUClock && count >= 2 ? .milliseconds(20) : .zero
        })
        let guards = try CompiledGuards([GuardPattern(name: "slow", regex: "^(a+)+$")])
        GuardBudgetClock.$current.withValue(clock) {
            #expect(guards.hits(in: [String(repeating: "a", count: 2_000) + "!"])
                    == [GuardHit(name: "slow", outcome: .timeout)])
        }
        #expect(cpuReads.withLock { $0 } >= 3, "the budget expires after entering ICU")
    }

    @Test func anUnreadableCPUClockFailsClosed() throws {
        let guards = try CompiledGuards([GuardPattern(name: "rule", regex: "never")])
        for clock in [GuardBudgetClock.stepped(cpu: nil),
                      GuardBudgetClock(now: { ContinuousClock.now }, cpuNow: { nil })] {
            GuardBudgetClock.$current.withValue(clock) {
                #expect(guards.hits(in: [Self.benign]) == [GuardHit(name: "rule", outcome: .timeout)])
                #expect(guards.hits(in: []).isEmpty, "a paste-only request has no guard candidates")
            }
        }
    }

    @Test func CPUDeadlineIsSharedAcrossCandidateLinesButResetsPerRule() throws {
        let readings = Mutex(0)
        let base = ContinuousClock.now
        let clock = GuardBudgetClock(now: { base }, cpuNow: {
            // First rule: start, first line entry/completion, second line entry. Second rule starts fresh.
            let count = readings.withLock { count in defer { count += 1 }; return count }
            return .milliseconds(count < 3 ? 0 : 21)
        })
        let guards = try CompiledGuards([GuardPattern(name: "first", regex: "^z$"),
                                        GuardPattern(name: "second", regex: "^z$")])
        GuardBudgetClock.$current.withValue(clock) {
            #expect(guards.hits(in: ["a", "b"]) == [GuardHit(name: "first", outcome: .timeout)])
        }
    }
}

extension DangerousPatternTests {
    @Test(.frozenGuardBudget) func structuredHitsKeepRuleOrderAndJoinedLineMatches() throws {
        let guards = try CompiledGuards(DangerousPatternGuard.defaults)
        #expect(guards.hits(in: ["rm \\", "-rf /", "sudo ls"]) == [
            GuardHit(name: "rm -rf", outcome: .match), GuardHit(name: "sudo", outcome: .match)
        ])
        #expect(guards.hits(in: ["echo hi"]).isEmpty)
    }
}

extension PolicyEvaluationTests {
    @Test(arguments: [Tier.open, .confirm])
    func matchAndTimeoutEvidenceBothRequireConfirmation(tier: Tier) throws {
        let evaluator = try evaluator(tier: tier)
        let request = DeliveryRequest(target: id, binding: binding, lines: ["sudo ls"], device: "ipad")
        let matched = evaluator.evaluateWithEvidence(request, lockdown: false, limiter: RateLimiter(), now: now)
        #expect(matched.guardOutcomes == [GuardHit(name: "sudo", outcome: .match)])
        guard case .confirm = matched.decision else { Issue.record("match must confirm"); return }
        let timedOut = GuardBudgetClock.$current.withValue(.expiring()) {
            evaluator.evaluateWithEvidence(request, lockdown: false, limiter: RateLimiter(), now: now)
        }
        #expect(!timedOut.guardOutcomes.isEmpty)
        #expect(timedOut.guardOutcomes.allSatisfy { $0.outcome == .timeout })
        guard case .confirm(_, let names) = timedOut.decision else {
            Issue.record("timeout must confirm"); return
        }
        #expect(names == timedOut.guardOutcomes.map(\.name))
    }

    @Test func decisionAndEvidenceUseExactlyOneGuardScan() throws {
        let reads = Mutex(0)
        let base = ContinuousClock.now
        let clock = GuardBudgetClock(now: { base }, cpuNow: {
            let count = reads.withLock { count in defer { count += 1 }; return count }
            return count == 0 ? .zero : .milliseconds(21)
        })
        var policy = Policy(guardPatterns: [GuardPattern(name: "rule", regex: "never")])
        try policy.allow(id, binding: binding, tier: .open)
        let evaluator = try PolicyEvaluator(policy: policy)
        let request = DeliveryRequest(target: id, binding: binding, lines: ["echo hi"], device: "ipad")
        let result = GuardBudgetClock.$current.withValue(clock) {
            evaluator.evaluateWithEvidence(request, lockdown: false, limiter: RateLimiter(), now: now)
        }
        #expect(result.decision == .confirm(reason: "guarded: rule", guardHits: ["rule"]))
        #expect(result.guardOutcomes == [GuardHit(name: "rule", outcome: .timeout)])
        #expect(reads.withLock { $0 } == 2, "a second scan would complete cleanly under this clock")
    }

    @Test func denialsNeverReadTheGuardClocks() throws {
        let clock = GuardBudgetClock(now: { Issue.record("denial read wall clock"); return .now },
                                     cpuNow: { Issue.record("denial read CPU clock"); return nil })
        let request = DeliveryRequest(target: id, binding: binding, lines: ["sudo ls"], device: "ipad")
        let evaluator = try evaluator(tier: .locked)
        GuardBudgetClock.$current.withValue(clock) {
            let locked = evaluator.evaluateWithEvidence(request, lockdown: false, limiter: RateLimiter(), now: now)
            #expect(locked.decision == .denied(.locked(id)))
            #expect(locked.guardOutcomes.isEmpty)
            let lockdown = evaluator.evaluateWithEvidence(request, lockdown: true, limiter: RateLimiter(), now: now)
            #expect(lockdown.decision == .denied(.lockdown))
            #expect(lockdown.guardOutcomes.isEmpty)
        }
    }
}

extension ConfirmationFlowTests {
    @Test func readBackCarriesMatchAndTimeoutEvidenceWithoutDelivering() async throws {
        let fx = try await fixture(policy: Policy(guardPatterns: [GuardPattern(name: "rule", regex: "sudo")]),
                                   tier: .open)
        let matched = try readBack(try await fx.host.send("sudo ls", to: id))
        #expect(matched.guardOutcomes == [GuardHit(name: "rule", outcome: .match)])
        let timeout = try await GuardBudgetClock.$current.withValue(.stepped(cpu: .milliseconds(21))) {
            try readBack(try await fx.host.send("echo hi", to: id))
        }
        #expect(timeout.guardHits == ["rule"])
        #expect(timeout.guardOutcomes == [GuardHit(name: "rule", outcome: .timeout)])
        #expect(await fx.adapter.deliveries.isEmpty)
    }
}
