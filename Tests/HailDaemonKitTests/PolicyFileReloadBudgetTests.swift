import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

private final class MovingPolicyReloadStore: PolicyChangeTracking {
    private let reads = Mutex(0)
    private let observations = Mutex(0)
    let clock = PolicyReloadTestClock()
    let readCost: Duration
    let moves: Bool
    let summary = "synthetic"

    init(readCost: Duration, moves: Bool = true) {
        self.readCost = readCost
        self.moves = moves
    }

    var loads: Int { reads.withLock { $0 } }
    var stamps: Int { observations.withLock { $0 } }
    var reloadNow: ContinuousClock.Instant { clock.now }
    func observation() -> PolicyObservation {
        observations.withLock { $0 += 1 }
        return stamp
    }
    private var stamp: PolicyObservation {
        PolicyObservation(identity: PolicyFileIdentity(device: 0, inode: 0, modified: .zero,
                                                      size: moves ? Int64(loads) : 0))
    }
    func load() throws -> Policy { try loadObserved().policy }
    func loadObserved() throws -> ObservedPolicy {
        let before = stamp
        reads.withLock { $0 += 1 }
        clock.advance(readCost)
        return ObservedPolicy(policy: Policy(), observation: before)
    }
    func update(_ change: (inout Policy) throws -> Void) throws -> PolicyUpdate {
        var policy = Policy()
        try change(&policy)
        return PolicyUpdate(policy: policy)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct PolicyFileReloadBudgetTests {
    @Test func movingIdentityStopsAfterThreeReadsWithoutSleeping() throws {
        let store = MovingPolicyReloadStore(readCost: .milliseconds(1))
        #expect(throws: HostError.policyUnavailable("policy_changed_during_reload")) { try store.loadStable() }
        #expect(store.loads == 3)
        #expect(store.clock.delay == .milliseconds(3))
        #expect(store.clock.delay < .milliseconds(50))
    }

    @Test func exhaustedTimeBudgetPreventsThirdRead() throws {
        let store = MovingPolicyReloadStore(readCost: .milliseconds(25))
        #expect(throws: HostError.policyUnavailable("policy_changed_during_reload")) { try store.loadStable() }
        #expect(store.loads == 2)
        #expect(store.clock.delay == .milliseconds(50))
    }

    @Test func overrunningReadSkipsFurtherObservationsAndFailsClosed() throws {
        let store = MovingPolicyReloadStore(readCost: .milliseconds(60))
        let authority = TargetPolicyAuthority(store: store)
        var policy = Policy()
        try policy.allow("tmux:a", binding: "$1@1/%1:1", tier: .open)
        try policy.allow("tmux:b", binding: "$2@1/%2:2", tier: .open)
        authority.update(policy)
        let retained = ["tmux:a", "tmux:b"].map { authority.snapshot(for: $0) }
        #expect(throws: (any Error).self) { try authority.refreshIfChanged() }
        #expect(store.loads == 1, "No second read may start after the budget expires")
        #expect(store.stamps == 1, "An overrun must stop before the post-read observation")
        #expect(store.clock.delay == .milliseconds(60))
        for grant in retained { #expect(grant.performIfCurrent({ true }) == nil) }
        for target in ["tmux:a", "tmux:b"] { #expect(!authority.snapshot(for: target).wasGranted) }
    }

    @Test(arguments: [49, 50]) func stableReadMustFinishWithinBudget(_ milliseconds: Int64) throws {
        let store = MovingPolicyReloadStore(readCost: .milliseconds(milliseconds), moves: false)
        if milliseconds < 50 {
            #expect(try store.loadStable().policy == Policy())
        } else {
            #expect(throws: HostError.policyUnavailable("policy_changed_during_reload")) { try store.loadStable() }
        }
        #expect(store.loads == 1)
    }
}
