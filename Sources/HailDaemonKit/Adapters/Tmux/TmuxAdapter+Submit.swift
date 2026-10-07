import Foundation
import OSLog
import Synchronization

private let submitLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "tmux-submit")

/// How long the adapter waits around the Enter (#83). A full-screen TUI can treat a burst of `send-keys -l`
/// text as a paste and swallow an Enter that arrives while it is still handling that paste, leaving the text
/// typed but unsubmitted. Every wait is bounded, and none of it depends on which program runs in the pane.
public struct TmuxSubmitTiming: Sendable, Equatable {
    /// The least time between the last chunk and the Enter.
    public var settleFloor: Duration
    /// How often the pane is captured while waiting for it to settle or to react.
    public var pollInterval: Duration
    /// The longest wait for a settled screen before the Enter is sent anyway.
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

/// What one submit observed (#83). Logged without pane contents, so a live session shows whether the retry
/// is what got text through.
public enum TmuxSubmitOutcome: String, Sendable, Equatable {
    /// The pane changed after the first Enter.
    case confirmed
    /// The first Enter left the pane unchanged; the pane changed after the one retry.
    case retried
    /// Blank, unreadable, or never visibly holding the typed text: one Enter, nothing to confirm against.
    case unverifiable
    /// The pane never stopped changing before the settle limit: one Enter, no confirmation.
    case unsettled
    /// Still unchanged after the retry, or the retry was refused; the delivery fails and taints the pane.
    case failed

    func record(target: String, observer: (@Sendable (TmuxSubmitOutcome) -> Void)?) {
        submitLogger.notice("tmux submit \(self.rawValue, privacy: .public) for \(target, privacy: .private)")
        observer?(self)
    }
}

/// The pane-observation half of the submit, apart from the actor so each stays readable. `capture` returns
/// the visible pane, or nil when it cannot be read, which makes the submit unverifiable rather than failed.
enum TmuxSubmitProbe {
    /// The pane's visible screen, or nil when tmux cannot capture it.
    static func visible(_ paneID: String, runner: any CommandRunner, tmux: String, base: [String]) async -> String? {
        let arguments = base + ["capture-pane", "-p", "-t", paneID]
        guard let result = try? await runner.run(tmux, arguments), result.exitCode == 0 else { return nil }
        return result.stdout
    }

    /// The screen to confirm the Enter against, or why there is none.
    enum Settled: Equatable { case screen(String), unchanged, unsettled, unreadable }

    /// After the floor, captures until two in a row match and show something new: the typed text has been
    /// drawn. A busy TUI can keep showing the screen from before the text (`baseline`) for a while; a stable
    /// copy of that is not accepted, or the Enter would be confirmed against a screen that never held the
    /// text. A blank stable screen is accepted as is (nothing to confirm). All of it is capped by the limit.
    static func settle(
        _ timing: TmuxSubmitTiming, baseline: String?, capture: @Sendable () async -> String?
    ) async -> Settled {
        try? await Task.sleep(for: timing.settleFloor)
        let deadline = ContinuousClock.now.advanced(by: timing.settleLimit)
        guard var previous = await capture() else { return .unreadable }
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: timing.pollInterval)
            guard let current = await capture() else { return .unreadable }
            let drawn = current != baseline || !current.contains(where: { !$0.isWhitespace })
            if current == previous, drawn { return .screen(current) }
            previous = current
        }
        return previous == baseline ? .unchanged : .unsettled
    }

    /// What the pane did after an Enter. Only `unchanged` is evidence that the text is still pending.
    enum Reaction: Equatable { case changed, unchanged, unreadable }

    /// Whether the pane moved off `before` within the confirm limit after an Enter. A pane left exactly as it
    /// was means the Enter was swallowed and the text is still pending, which is the only case the adapter
    /// retries. The edge this accepts: a first Enter that was taken late (delayed, not swallowed) and drew
    /// nothing for the whole confirm window gets a retry that lands on an empty input (a no-op in most TUIs,
    /// an empty prompt line in a shell). Requiring the screen to be exactly unchanged, not merely still showing
    /// the text, confines that to a target that drew nothing at all for the full window; a busy TUI's spinner,
    /// a cleared input line, or a shell's echo all count as a change and suppress the retry.
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
