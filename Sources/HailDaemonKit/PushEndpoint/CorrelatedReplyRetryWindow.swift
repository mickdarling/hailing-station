/// Bounds the start of retries, not the first transaction's existing socket timeout.
/// A pending refusal promises zero publication; other outcomes never reach this retry policy.
package struct CorrelatedReplyRetryWindow: Sendable {
    package static let maximumAttempts = 8
    private static let delay: Duration = .milliseconds(100)
    private let deadline: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    package init() {
        self.init(now: { ContinuousClock.now }, sleep: { try await Task.sleep(for: $0) })
    }

    /// Internal injection makes delayed resumption causal in tests, without sleeping or scheduler assumptions.
    init(now: @escaping @Sendable () -> ContinuousClock.Instant,
         sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
        deadline = now().advanced(by: .seconds(2))
    }

    package func canStart(attempt: Int) -> Bool {
        guard attempt >= 0, attempt < Self.maximumAttempts else { return false }
        return attempt == 0 || now() < deadline
    }

    package func waitForRetry(after attempt: Int) async throws -> Bool {
        try Task.checkCancellation()
        guard attempt >= 0, attempt < Self.maximumAttempts - 1,
              now().advanced(by: Self.delay) < deadline else { return false }
        try await sleep(Self.delay)
        try Task.checkCancellation()
        return canStart(attempt: attempt + 1)
    }
}
