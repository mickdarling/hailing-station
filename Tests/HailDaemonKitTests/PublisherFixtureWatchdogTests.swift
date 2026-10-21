import Foundation
import Testing

/// #740: a publisher fixture wait that gives up names its call site and how it spent the time.
@Suite struct PublisherFixtureWatchdogTests {
    @Test func aWaitThatNeverComesTrueNamesItsCallSiteAndItsPolls() async throws {
        let line = #line + 2
        do {
            try await PublisherFixture.until(timeout: .milliseconds(100)) { false }
            Issue.record("the wait returned for a condition that was never true")
        } catch let PublisherFixtureFailure.watchdog(at, elapsed, polls, _) {
            #expect(at == "HailDaemonKitTests/PublisherFixtureWatchdogTests.swift:\(line)")
            #expect(elapsed >= .milliseconds(100))
            #expect(polls > 1)
        }
    }

    @Test func aWaitThatComesTrueReturns() async throws {
        try await PublisherFixture.until(timeout: .milliseconds(100)) { true }
    }
}
