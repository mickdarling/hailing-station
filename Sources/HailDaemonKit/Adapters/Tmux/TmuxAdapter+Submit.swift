import Foundation
import OSLog

private let submitLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "tmux-submit")

/// How long the adapter waits around the Enter (#83, #304). A TUI whose event loop stalls (a large session paging
/// back in after idle) reads queued input late; an Enter that reaches it in the same read as typed text is taken
/// as a newline, not a submit. The text therefore goes in as one bracketed paste, and the Enter waits until the
/// pane shows the text at the cursor. Every wait is bounded.
public struct TmuxSubmitTiming: Sendable, Equatable {
    /// The least time between the paste and the first look at the pane.
    public var settleFloor: Duration
    /// How often the pane is observed while waiting.
    public var pollInterval: Duration
    /// How long the pane must show the text at the cursor, unchanged, before the Enter. Above Claude Code's
    /// 100 ms paste-completion window.
    public var quiet: Duration
    /// The longest wait for the text to appear at the cursor before the Enter is sent anyway (`unsettled`).
    public var settleLimit: Duration
    /// The longest wait after an Enter for the text to leave the cursor, and for a pending pane to hold still.
    public var confirmLimit: Duration

    public init(
        settleFloor: Duration, pollInterval: Duration, quiet: Duration, settleLimit: Duration, confirmLimit: Duration
    ) {
        self.settleFloor = settleFloor
        self.pollInterval = pollInterval
        self.quiet = quiet
        self.settleLimit = settleLimit
        self.confirmLimit = confirmLimit
    }

    public static let standard = TmuxSubmitTiming(
        settleFloor: .milliseconds(50), pollInterval: .milliseconds(50), quiet: .milliseconds(150),
        settleLimit: .seconds(5), confirmLimit: .seconds(2)
    )
}

/// What one submit observed (#83, #304). Logged without pane contents.
public enum TmuxSubmitOutcome: String, Sendable, Equatable {
    /// The text was seen at the cursor, and after the first Enter it no longer was.
    case confirmed
    /// The text stayed at the cursor after the first Enter; it left after the one retry.
    case retried
    /// The pane was blank or unreadable, or what followed the Enter cannot tell a submit from a wrapped row.
    case unverifiable
    /// The text never appeared at the cursor within the settle limit; one Enter, sent anyway.
    case unsettled
    /// Still at the cursor after the retry, or the retry was refused; the delivery fails and taints the pane.
    case failed

    func record(target: String, observer: (@Sendable (TmuxSubmitOutcome) -> Void)?) {
        submitLogger.notice("tmux submit \(self.rawValue, privacy: .public) for \(target, privacy: .private)")
        observer?(self)
    }
}

/// The waits of the submit, apart from the actor so each stays readable. `observe` returns nil when the pane
/// cannot be read, which makes the submit unverifiable rather than failed.
enum TmuxSubmitProbe {
    typealias Observe = @Sendable () async -> PaneObservation?

    static func observe(
        _ paneID: String, runner: any CommandRunner, tmux: String, base: [String]
    ) async -> PaneObservation? {
        let arguments = base + ["capture-pane", "-p", "-t", paneID, ";",
                                "display-message", "-p", "-t", paneID, PaneObservation.cursorFormat]
        guard let result = try? await runner.run(tmux, arguments), result.exitCode == 0 else { return nil }
        return PaneObservation(captured: result.stdout)
    }

    enum Acceptance: Equatable { case accepted(PaneObservation), blank, unreadable, timedOut }

    /// After the floor, waits until the pane differs from `baseline` and shows the text (or a placeholder) at the
    /// cursor, unchanged for `quiet`: the target has taken the whole paste in. A blank pane has nothing to show.
    static func acceptance(
        _ timing: TmuxSubmitTiming, baseline: PaneObservation?, tail: PayloadTail, observe: Observe
    ) async -> Acceptance {
        try? await Task.sleep(for: timing.settleFloor)
        let deadline = ContinuousClock.now.advanced(by: timing.settleLimit)
        var steady: (PaneObservation, ContinuousClock.Instant)?
        while true {
            guard let current = await observe() else { return .unreadable }
            if current.isBlank { return .blank }
            if current != baseline, current.input(tail) != .clear {
                if let (seen, since) = steady, seen == current {
                    if ContinuousClock.now - since >= timing.quiet { return .accepted(current) }
                } else {
                    steady = (current, .now)
                }
            } else {
                steady = nil
            }
            guard ContinuousClock.now < deadline else { return .timedOut }
            try? await Task.sleep(for: timing.pollInterval)
        }
    }

    /// What the pane showed after an Enter.
    enum Reaction: Equatable { case submitted, pending, ambiguous, unreadable }

    /// Waits up to the confirm limit for the text to leave the cursor. Only text still held at the cursor for the
    /// whole window is `pending`. A cursor that moved to column 0 right after the text is a submit only when the
    /// cursor was past column 0 before the Enter (a terminal ended the line); otherwise it is `ambiguous`.
    static func reaction(
        _ timing: TmuxSubmitTiming, tail: PayloadTail, wasHolding: Bool, observe: Observe
    ) async -> Reaction {
        let deadline = ContinuousClock.now.advanced(by: timing.confirmLimit)
        repeat {
            try? await Task.sleep(for: timing.pollInterval)
            guard let current = await observe() else { return .unreadable }
            switch current.input(tail) {
            case .clear: return .submitted
            case .lineEnded: return wasHolding ? .submitted : .ambiguous
            case .holding: continue
            }
        } while ContinuousClock.now < deadline
        return .pending
    }

    enum Steadiness: Equatable { case holding, released, restless }

    /// Before the retry: the text must still be held at the cursor, unchanged for `quiet`, so the target is
    /// drawing again and not frozen mid-read (`holding`). `released`: it took the first Enter late (the text left
    /// the cursor). `restless`: the pane never held still within the confirm limit, or could not be read.
    static func steadiness(_ timing: TmuxSubmitTiming, tail: PayloadTail, observe: Observe) async -> Steadiness {
        let deadline = ContinuousClock.now.advanced(by: timing.confirmLimit)
        var steady: (PaneObservation, ContinuousClock.Instant)?
        while ContinuousClock.now < deadline {
            guard let current = await observe() else { return .restless }
            guard current.input(tail) == .holding else { return .released }
            if let (seen, since) = steady, seen == current {
                if ContinuousClock.now - since >= timing.quiet { return .holding }
            } else {
                steady = (current, .now)
            }
            try? await Task.sleep(for: timing.pollInterval)
        }
        return .restless
    }

    /// The outcome a first reaction settles, or nil when the text is still pending and a retry may follow.
    static func outcome(of reaction: Reaction, wasHolding: Bool, acceptance: Acceptance) -> TmuxSubmitOutcome? {
        let undecided: TmuxSubmitOutcome = acceptance == .timedOut ? .unsettled : .unverifiable
        switch reaction {
        case .submitted: return wasHolding ? .confirmed : undecided
        case .ambiguous, .unreadable: return undecided
        case .pending: return nil
        }
    }
}

extension TmuxAdapter {
    /// Sends the Enter and decides the outcome from what the pane shows at the cursor. Text still held there for
    /// the whole confirm window gets one more Enter, only once the pane holds steady again (identity re-checked
    /// first); still held after that fails the delivery, which taints the pane.
    func attemptSubmit(
        _ session: Session, target: String, tail: PayloadTail, acceptance: TmuxSubmitProbe.Acceptance
    ) async throws -> TmuxSubmitOutcome {
        let enter = ["send-keys", "-t", session.paneID, "Enter"]
        try await tmux(enter, failure: AdapterError.deliveryFailed)
        let observe: TmuxSubmitProbe.Observe = { await self.observePane(session.paneID) }
        let wasHolding: Bool
        switch acceptance {
        case .blank, .unreadable: return .unverifiable
        case .timedOut: wasHolding = false
        case .accepted(let seen): wasHolding = seen.input(tail) == .holding
        }
        let first = await TmuxSubmitProbe.reaction(submitTiming, tail: tail, wasHolding: wasHolding, observe: observe)
        if let settled = TmuxSubmitProbe.outcome(of: first, wasHolding: wasHolding, acceptance: acceptance) {
            return settled
        }
        switch await TmuxSubmitProbe.steadiness(submitTiming, tail: tail, observe: observe) {
        case .released: return .confirmed
        case .restless: return .unverifiable
        case .holding: break
        }
        _ = try await verified(target, binding: session.binding)
        try await tmux(enter, failure: AdapterError.deliveryFailed)
        switch await TmuxSubmitProbe.reaction(submitTiming, tail: tail, wasHolding: true, observe: observe) {
        case .submitted: return .retried
        case .ambiguous, .unreadable: return .unverifiable
        case .pending: throw AdapterError.deliveryFailed("the Enter was not observed to submit the text in \(target)")
        }
    }
}
