import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct PolicyEvaluationTests {
    let now = ContinuousClock().now
    let id = "tmux:claude-hail"
    let binding = "$1@1/%1:9"

    /// An evaluator whose policy allows the test target as given; `tier: nil` leaves it unallowed.
    func evaluator(tier: Tier? = .confirm, capture: Bool = false, perMinute: Int = 30) throws -> PolicyEvaluator {
        var policy = Policy(deliveriesPerMinute: perMinute)
        if let tier { try policy.allow(id, binding: binding, tier: tier, capture: capture) }
        return try PolicyEvaluator(policy: policy)
    }

    func decide(_ evaluator: PolicyEvaluator, lines: [String] = ["echo hi"], binding: String? = "$1@1/%1:9",
                lockdown: Bool = false, limiter: RateLimiter = RateLimiter()) -> Decision {
        let request = DeliveryRequest(target: id, binding: binding, lines: lines, device: "ipad")
        return evaluator.evaluate(request, lockdown: lockdown, limiter: limiter, now: now)
    }

    @Test func freshTargetIsDeniedUntilAllowed() throws {
        #expect(decide(try evaluator(tier: nil)) == .denied(.notAllowed(id)))
    }

    @Test func allowDefaultsToConfirmTierAndStillReportsGuardHits() throws {
        let evaluator = try evaluator()
        #expect(evaluator.policy.targets[id] == TargetPolicy(tier: .confirm, capture: false, binding: binding))
        #expect(decide(evaluator) == .confirm(reason: "confirm tier", guardHits: []))
        #expect(decide(evaluator, lines: ["rm -rf /"]) == .confirm(reason: "confirm tier", guardHits: ["rm -rf"]))
    }

    @Test func openTargetDeliversAndGuardEscalatesItWithEveryHit() throws {
        let evaluator = try evaluator(tier: .open)
        #expect(decide(evaluator) == .deliver)
        #expect(decide(evaluator, lines: ["git push --force"])
            == .confirm(reason: "guarded: force push", guardHits: ["force push"]))
        #expect(decide(evaluator, lines: ["ok", "sudo rm -rf /"])
            == .confirm(reason: "guarded: rm -rf, sudo", guardHits: ["rm -rf", "sudo"]))
    }

    @Test func lockedTargetNeverDelivers() throws {
        let evaluator = try evaluator(tier: .locked)
        #expect(decide(evaluator) == .denied(.locked(id)))
    }

    @Test func aReboundTargetIsRefusedUntilReallowed() throws {
        let evaluator = try evaluator(tier: .open)
        #expect(decide(evaluator, binding: "$7@2/%3:44") == .denied(.rebound(id)))
        #expect(decide(evaluator, binding: nil) == .denied(.unbound(id)), "no listing binding: cannot match")
        #expect(decide(evaluator, binding: "") == .denied(.unbound(id)), "an empty binding matches nothing")
        #expect(decide(evaluator, binding: " \t") == .denied(.unbound(id)), "a blank binding matches nothing")
        var policy = evaluator.policy
        try policy.allow(id, binding: "$7@2/%3:44", tier: .open)
        #expect(decide(try PolicyEvaluator(policy: policy), binding: "$7@2/%3:44") == .deliver)
    }

    @Test func anEmptyBindingCannotBeAllowed() {
        var policy = Policy()
        #expect(throws: PolicyFormatError.emptyBinding(id)) { try policy.allow(id, binding: "") }
        #expect(throws: PolicyFormatError.emptyBinding(id)) { try policy.allow(id, binding: "  ") }
        #expect(policy.targets.isEmpty)
    }

    @Test func anInMemoryPolicyCannotContainAnEmptyTargetID() {
        let policy = Policy(targets: ["": TargetPolicy(tier: .open, binding: binding)])
        #expect(throws: PolicyFormatError.emptyTargetID) { try PolicyEvaluator(policy: policy) }
    }

    @Test func anExhaustedLimitIsReportedBeforeTheGuard() throws {
        let evaluator = try evaluator(tier: .open, perMinute: 1)
        var limiter = RateLimiter()
        limiter.record(DeliveryRequest(target: id, binding: binding, lines: ["x"], device: "ipad"), at: now)
        #expect(decide(evaluator, lines: ["rm -rf /"], limiter: limiter)
            == .denied(.rateLimited(retryAfter: .seconds(60))))
    }

    @Test func lockdownWinsOverEverything() throws {
        let evaluator = try evaluator(tier: .open)
        #expect(decide(evaluator, lockdown: true) == .denied(.lockdown))
        #expect(decide(try self.evaluator(tier: nil), lockdown: true) == .denied(.lockdown))
        var limiter = RateLimiter()
        limiter.record("target:" + id, at: now)
        #expect(decide(try self.evaluator(tier: .open, perMinute: 1), lockdown: true, limiter: limiter)
            == .denied(.lockdown))
        #expect(!evaluator.mayCapture(target: id, binding: binding, lockdown: true))
    }

    @Test func anEmptyDeliveryIsRefused() throws {
        #expect(decide(try evaluator(tier: .open), lines: []) == .denied(.emptyRequest))
        #expect(decide(try evaluator(tier: nil), lines: [], lockdown: true) == .denied(.lockdown))
    }

    @Test func rateLimitDeniesOnlyWhatWouldOtherwiseGoOut() throws {
        let evaluator = try evaluator(tier: .open, perMinute: 2)
        var limiter = RateLimiter()
        limiter.record("target:" + id, at: now - .seconds(30))
        limiter.record("target:" + id, at: now - .seconds(10))
        #expect(decide(evaluator, limiter: limiter) == .denied(.rateLimited(retryAfter: .seconds(30))))
        // A refused target does not consume the budget and is reported as its own denial.
        #expect(decide(evaluator, binding: nil, limiter: limiter) == .denied(.unbound(id)))
    }

    @Test func aTwentyLineRequestRequiresTwentyAvailableSlots() throws {
        let evaluator = try evaluator(tier: .open, perMinute: 30)
        let lines = Array(repeating: "echo hi", count: 20)
        var limiter = RateLimiter()
        for _ in 0..<10 { limiter.record("target:" + id, at: now) }
        #expect(decide(evaluator, lines: lines, limiter: limiter) == .deliver)
        limiter.record("target:" + id, at: now)
        #expect(decide(evaluator, lines: lines, limiter: limiter)
            == .denied(.rateLimited(retryAfter: .seconds(60))))
    }

    @Test func rateLimitAppliesPerDeviceTooInItsOwnKeySpace() throws {
        let evaluator = try evaluator(tier: .open, perMinute: 1)
        var limiter = RateLimiter()
        limiter.record("device:ipad", at: now - .seconds(5))
        let fromIPad = DeliveryRequest(target: id, binding: binding, lines: ["ok"], device: "ipad")
        let fromPhone = DeliveryRequest(target: id, binding: binding, lines: ["ok"], device: "iphone")
        #expect(RateLimiter.keys(for: fromIPad) == ["target:" + id, "device:ipad"])
        #expect(evaluator.evaluate(fromIPad, lockdown: false, limiter: limiter, now: now)
            == .denied(.rateLimited(retryAfter: .seconds(55))))
        #expect(evaluator.evaluate(fromPhone, lockdown: false, limiter: limiter, now: now) == .deliver)
    }

    @Test func bothBudgetsExhaustedReportsTheLongerWait() throws {
        let evaluator = try evaluator(tier: .open, perMinute: 1)
        var limiter = RateLimiter()
        limiter.record("target:" + id, at: now - .seconds(50))
        limiter.record("device:ipad", at: now - .seconds(10))
        #expect(decide(evaluator, limiter: limiter) == .denied(.rateLimited(retryAfter: .seconds(50))))
    }

    @Test func captureIsItsOwnPermission() throws {
        let evaluator = try evaluator(tier: .locked, capture: true)
        #expect(evaluator.mayCapture(target: id, binding: binding, lockdown: false))
        #expect(!evaluator.mayCapture(target: id, binding: "other", lockdown: false))
        #expect(!evaluator.mayCapture(target: "tmux:unknown", binding: binding, lockdown: false))
        let closed = try self.evaluator(tier: .open)
        #expect(!closed.mayCapture(target: id, binding: binding, lockdown: false), "open tier, capture off")
    }
}
