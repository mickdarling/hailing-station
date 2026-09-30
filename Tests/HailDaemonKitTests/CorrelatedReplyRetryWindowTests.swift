import Synchronization
import Testing
@testable import HailDaemonKit

/// No sockets, speech, real sleeps or scheduling assumptions. The injected sleeper advances a synthetic clock.
@Suite struct CorrelatedReplyRetryWindowTests {
    @Test func openDeadlinePermitsExactlyEightAttemptsAndSevenWaits() async throws {
        let clock = RetryWindowTestClock()
        let sleeps = Mutex(0)
        let policy = CorrelatedReplyRetryWindow(now: clock.now, sleep: { duration in
            #expect(duration == .milliseconds(100))
            sleeps.withLock { $0 += 1 }
            clock.advance(duration)
        })
        for attempt in 0..<8 {
            #expect(policy.canStart(attempt: attempt))
            #expect(try await policy.waitForRetry(after: attempt) == (attempt < 7))
        }
        #expect(!policy.canStart(attempt: 8))
        #expect(sleeps.withLock { $0 } == 7)
    }

    @Test func delayedResumptionNeverPermitsAnotherTransaction() async throws {
        let clock = RetryWindowTestClock()
        let policy = CorrelatedReplyRetryWindow(now: clock.now, sleep: { duration in
            #expect(duration == .milliseconds(100))
            clock.advance(.seconds(3))
        })
        #expect(policy.canStart(attempt: 0))
        #expect(!(try await policy.waitForRetry(after: 0)))
        #expect(!policy.canStart(attempt: 1))
    }

    @Test func deadlineIsRecheckedImmediatelyBeforeStartingEvenAfterPermittedWait() async throws {
        let clock = RetryWindowTestClock()
        let policy = CorrelatedReplyRetryWindow(now: clock.now, sleep: { clock.advance($0) })
        #expect(try await policy.waitForRetry(after: 0))
        clock.advance(.seconds(2))
        #expect(!policy.canStart(attempt: 1))
    }

    @Test func attemptCapAndDeadlineRefuseWithoutSleeping() async throws {
        let clock = RetryWindowTestClock()
        let sleeps = Mutex(0)
        let policy = CorrelatedReplyRetryWindow(now: clock.now, sleep: { _ in sleeps.withLock { $0 += 1 } })
        #expect(!policy.canStart(attempt: -1))
        #expect(!policy.canStart(attempt: 8))
        #expect(!(try await policy.waitForRetry(after: -1)))
        #expect(!(try await policy.waitForRetry(after: 7)))
        clock.advance(.milliseconds(1_900))
        #expect(!(try await policy.waitForRetry(after: 0)))
        #expect(sleeps.withLock { $0 } == 0)
        // The first socket transaction has a separate timeout; the window bounds retries only.
        clock.advance(.seconds(1))
        #expect(policy.canStart(attempt: 0))
        #expect(!policy.canStart(attempt: 1))
    }

    @Test func cancellationDuringWaitPropagatesInsteadOfStartingRetry() async throws {
        let clock = RetryWindowTestClock()
        let policy = CorrelatedReplyRetryWindow(now: clock.now, sleep: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task { try await policy.waitForRetry(after: 0) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private final class RetryWindowTestClock: Sendable {
    private let origin = ContinuousClock.now
    private let elapsed = Mutex(Duration.zero)
    func now() -> ContinuousClock.Instant { origin.advanced(by: elapsed.withLock { $0 }) }
    func advance(_ duration: Duration) { elapsed.withLock { $0 += duration } }
}
