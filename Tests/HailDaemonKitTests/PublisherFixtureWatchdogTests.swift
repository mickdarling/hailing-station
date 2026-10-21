import Foundation
import Synchronization
import Testing

/// #740: a publisher fixture wait that gives up names its call site and how it spent the time.
@Suite struct PublisherFixtureWatchdogTests {
    @Test func aWaitThatNeverComesTrueNamesItsCallSiteAndItsPolls() async throws {
        let line = #line + 2
        do {
            try await PublisherFixture.until(timeout: .milliseconds(100)) { false }
            Issue.record("the wait returned for a condition that was never true")
        } catch let PublisherFixtureFailure.watchdog(at, limit, elapsed, polls, _) {
            #expect(at == "HailDaemonKitTests/PublisherFixtureWatchdogTests.swift:\(line)")
            #expect(limit == "poll budget")
            #expect(elapsed >= .milliseconds(100))
            #expect(polls > 1)
        }
    }

    /// A stall longer than the whole timeout, as on a stalled CI runner (#704), does not use up the budget.
    @Test func aStallLongerThanTheTimeoutDoesNotFailTheWait() async throws {
        let calls = Mutex(0)
        try await PublisherFixture.until(timeout: .milliseconds(100)) {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { try? await Task.sleep(for: .milliseconds(300)) }
            return call >= 3
        }
        #expect(calls.withLock { $0 } == 3)
    }

    /// Repeated stalls never spend the poll budget, so the wall cap ends the wait and says so.
    @Test func repeatedStallsHitTheWallCap() async throws {
        do {
            try await PublisherFixture.until(timeout: .seconds(10), wallCap: .milliseconds(200)) {
                try? await Task.sleep(for: .milliseconds(100))
                return false
            }
            Issue.record("the wait returned for a condition that was never true")
        } catch let PublisherFixtureFailure.watchdog(_, limit, elapsed, _, _) {
            #expect(limit == "wall cap")
            #expect(elapsed >= .milliseconds(200))
        }
    }

    @Test func aWaitThatComesTrueReturns() async throws {
        try await PublisherFixture.until(timeout: .milliseconds(100)) { true }
    }
}
