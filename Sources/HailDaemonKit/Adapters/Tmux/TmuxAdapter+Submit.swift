import Foundation
import Synchronization

/// How long the adapter waits around the Enter (#83). A full-screen TUI can treat a burst of `send-keys -l`
/// text as a paste and swallow an Enter that arrives while it is still handling that paste, leaving the text
/// typed but unsubmitted. Every wait is bounded, and none of it depends on which program runs in the pane.
public struct TmuxSubmitTiming: Sendable, Equatable {
    /// The least time between the last chunk and the Enter.
    public var settleFloor: Duration
    /// How often the pane is captured while waiting for it to settle or to react.
    public var pollInterval: Duration
    /// The longest wait for two identical captures before the Enter is sent anyway.
    public var settleLimit: Duration
    /// The longest wait after an Enter for the pane to change.
    public var confirmLimit: Duration

    public init(settleFloor: Duration, pollInterval: Duration, settleLimit: Duration, confirmLimit: Duration) {
        self.settleFloor = settleFloor
        self.pollInterval = pollInterval
        self.settleLimit = settleLimit
        self.confirmLimit = confirmLimit
    }

    public static let standard = TmuxSubmitTiming(
        settleFloor: .milliseconds(150), pollInterval: .milliseconds(50),
        settleLimit: .seconds(1), confirmLimit: .seconds(1)
    )
}

/// The pane-observation half of the submit, apart from the actor so each stays readable. `capture` returns
/// the visible pane, or nil when it cannot be read, which makes the submit unverifiable rather than failed.
enum TmuxSubmitProbe {
    /// The pane once it stops changing after the last chunk: the floor, then captures until two match or the
    /// limit passes. Nil when the pane cannot be read.
    static func settle(_ timing: TmuxSubmitTiming, capture: @Sendable () async -> String?) async -> String? {
        try? await Task.sleep(for: timing.settleFloor)
        let deadline = ContinuousClock.now.advanced(by: timing.settleLimit)
        guard var previous = await capture() else { return nil }
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: timing.pollInterval)
            guard let current = await capture() else { return nil }
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    /// What the pane did after an Enter. Only `unchanged` is evidence that the text is still pending.
    enum Reaction: Equatable { case changed, unchanged, unreadable }

    /// Whether the pane moved off `before` within the confirm limit after an Enter.
    static func reaction(
        from before: String, _ timing: TmuxSubmitTiming, capture: @Sendable () async -> String?
    ) async -> Reaction {
        let deadline = ContinuousClock.now.advanced(by: timing.confirmLimit)
        repeat {
            try? await Task.sleep(for: timing.pollInterval)
            guard let current = await capture() else { return .unreadable }
            if current != before { return .changed }
        } while ContinuousClock.now < deadline
        return .unchanged
    }
}

/// One delivery's submit decision: the caller's cancellation and the Enter race for it under one lock.
final class DeliveryAbandonment: Sendable {
    private enum State { case pending, abandoned, committed }
    private let state = Mutex(State.pending)
    /// Abandons a delivery that has not committed; a committed one is unaffected.
    func abandon() { state.withLock { if $0 == .pending { $0 = .abandoned } } }
    func check() throws { if state.withLock({ $0 == .abandoned }) { throw CancellationError() } }
    /// True exactly once, for a delivery not yet abandoned; from then on abandonment cannot stop the Enter.
    func commit() -> Bool {
        state.withLock {
            guard $0 == .pending else { return false }
            $0 = .committed
            return true
        }
    }
}
