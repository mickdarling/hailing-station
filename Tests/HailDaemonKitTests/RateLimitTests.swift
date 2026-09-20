import Testing
@testable import HailDaemonKit

@Suite struct RateLimitTests {
    let start = ContinuousClock().now

    func at(_ seconds: Double) -> RateLimiter.Instant { start + .seconds(seconds) }

    @Test func engagesAtTheLimitAndClearsAsTheWindowSlides() {
        var limiter = RateLimiter()
        for second in 0..<30 { limiter.record("t", at: at(Double(second))) }
        #expect(limiter.retryAfter(for: "t", now: at(30), limitPerMinute: 30) == .seconds(30))
        #expect(limiter.retryAfter(for: "t", now: at(60), limitPerMinute: 30) == nil)
        #expect(limiter.retryAfter(for: "t", now: at(59.5), limitPerMinute: 30) == .seconds(0.5))
    }

    @Test func keysAreIndependentAndOldEntriesAreForgotten() {
        var limiter = RateLimiter()
        limiter.record("a", at: start)
        #expect(limiter.retryAfter(for: "b", now: start, limitPerMinute: 1) == nil)
        #expect(limiter.retryAfter(for: "a", now: start, limitPerMinute: 1) == .seconds(60))
        limiter.record("a", at: at(120))
        var expected = RateLimiter()
        expected.record("a", at: at(120))
        #expect(limiter == expected, "the entry from two minutes ago was dropped on record")
    }

    @Test func aLoweredLimitWaitsUntilTheWindowIsBelowIt() {
        var limiter = RateLimiter()
        for second in [0.0, 10, 20] { limiter.record("t", at: at(second)) }
        // Three in the window, limit two: the entry at 10 s must expire, not only the one at 0 s.
        #expect(limiter.retryAfter(for: "t", now: at(30), limitPerMinute: 2) == .seconds(40))
        #expect(limiter.retryAfter(for: "t", now: at(70), limitPerMinute: 2) == nil)
    }

    @Test func aBatchNeedsCapacityForEveryDelivery() {
        var limiter = RateLimiter()
        for second in 0..<11 { limiter.record("t", at: at(Double(second))) }
        #expect(limiter.retryAfter(for: "t", now: at(20), limitPerMinute: 30, consuming: 20) == .seconds(40))
        #expect(limiter.retryAfter(for: "t", now: at(60), limitPerMinute: 30, consuming: 20) == nil)
        #expect(limiter.retryAfter(for: "t", now: start, limitPerMinute: 19, consuming: 20) == .seconds(60))
    }

    @Test func invalidNoOpAndExtremeBatchCountsAreBounded() {
        var limiter = RateLimiter()
        limiter.record("t", at: start)
        #expect(limiter.retryAfter(for: "t", now: start, limitPerMinute: 30, consuming: -1) == .seconds(60))
        #expect(limiter.retryAfter(for: "t", now: start, limitPerMinute: 30, consuming: 0) == nil)
        #expect(limiter.retryAfter(for: "t", now: start, limitPerMinute: .max, consuming: .max) == .seconds(60))
    }

    @Test func zeroLimitRefusesEverything() {
        #expect(RateLimiter().retryAfter(for: "t", now: start, limitPerMinute: 0) == .seconds(60))
        #expect(RateLimiter().retryAfter(for: "t", now: start, limitPerMinute: -1) == .seconds(60))
    }

    @Test func instantsAreMonotonicSoAWallClockStepCannotMatter() {
        // A ContinuousClock instant is not a Date: there is no way to hand the limiter a stepped clock.
        // What can happen is an earlier instant being asked about; the answer is bounded by the window.
        var limiter = RateLimiter()
        limiter.record("t", at: at(5))
        #expect(limiter.retryAfter(for: "t", now: start, limitPerMinute: 1) == .seconds(60))
    }

    @Test func staleKeysArePrunedOnRecord() {
        var limiter = RateLimiter()
        limiter.record("old", at: start)
        limiter.record("new", at: at(61))
        var expected = RateLimiter()
        expected.record("new", at: at(61))
        #expect(limiter == expected, "the key with only stale entries is gone")
    }
}
