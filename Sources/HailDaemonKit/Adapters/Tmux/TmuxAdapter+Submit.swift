import Foundation
import OSLog

private let submitLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "tmux-submit")

/// How long the adapter waits around the Enter (#83, #304); every wait is bounded. `settleFloor`: paste to first
/// look. `pollInterval`: between looks. `quiet`: how long the text must show at the cursor, unchanged, before the
/// Enter (above Claude Code's 100 ms paste window). `settleLimit`: the longest wait for it to appear (then the Enter
/// goes anyway, `unsettled`). `confirmLimit`: the longest wait after an Enter for it to leave, or for a pending pane
/// to hold still. `clearLimit`: the longest wait before a paste for text already pending at the cursor to leave.
public struct TmuxSubmitTiming: Sendable, Equatable {
    public var settleFloor: Duration, pollInterval: Duration, quiet: Duration
    public var settleLimit: Duration, confirmLimit: Duration, clearLimit: Duration

    public init(
        settleFloor: Duration, pollInterval: Duration, quiet: Duration, settleLimit: Duration, confirmLimit: Duration,
        clearLimit: Duration = .seconds(3)
    ) {
        (self.settleFloor, self.pollInterval, self.quiet) = (settleFloor, pollInterval, quiet)
        (self.settleLimit, self.confirmLimit, self.clearLimit) = (settleLimit, confirmLimit, clearLimit)
    }

    public static let standard = TmuxSubmitTiming(
        settleFloor: .milliseconds(50), pollInterval: .milliseconds(50), quiet: .milliseconds(150),
        settleLimit: .seconds(4), confirmLimit: .seconds(2), clearLimit: .seconds(3)
    )
}

/// What one submit observed (#83, #304), logged without pane contents. `confirmed`: seen at the cursor, gone after
/// the first Enter. `retried`: gone only after the one retry. `unverifiable`: blank or unreadable, unchanged after
/// the Enter (a frozen target gets no second Enter), or not decidable. `unsettled`: never seen at the cursor within
/// the settle limit; one Enter anyway. `failed`: still there after the retry, or the retry refused (taints the pane).
public enum TmuxSubmitOutcome: String, Sendable, Equatable {
    case confirmed, retried, unverifiable, unsettled, failed
    func record(target: String, observer: (@Sendable (TmuxSubmitOutcome) -> Void)?) {
        submitLogger.notice("tmux submit \(self.rawValue, privacy: .public) for \(target, privacy: .private)")
        observer?(self)
    }
}

/// The waits of the submit, apart from the actor. An unreadable pane makes a submit unverifiable, never failed.
enum TmuxSubmitProbe {
    typealias Observe = @Sendable () async -> PaneObservation?
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
            if current != baseline, current.input(tail).isDrawn {
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

    /// What the pane showed after an Enter. `pending(alive:)`: whether the pane changed while the text stayed at the
    /// cursor; an unchanged pane may be frozen with the Enter queued (a second Enter would join it as a newline).
    enum Reaction: Equatable { case submitted, pending(alive: Bool), ambiguous, unreadable }

    /// Waits up to the confirm limit for the text to leave the cursor, seen on two looks in a row. A cursor that
    /// moved to column 0 right after the text counts only when the cursor was past column 0 before the Enter (a
    /// terminal ended the line); otherwise it is `ambiguous`.
    static func reaction(
        _ timing: TmuxSubmitTiming, tail: PayloadTail?, before: PaneObservation?, wasHolding: Bool, observe: Observe
    ) async -> Reaction {
        let deadline = ContinuousClock.now.advanced(by: timing.confirmLimit)
        var previous = before, alive = false, released = 0
        repeat {
            try? await Task.sleep(for: timing.pollInterval)
            guard let current = await observe() else { return .unreadable }
            alive = alive || (previous.map { $0 != current } ?? false)
            previous = current
            switch current.input(tail) {
            case .clear: released += 1
            case .lineEnded: if wasHolding { released += 1 } else { return .ambiguous }
            case .holding: released = 0
            }
            if released >= 2 { return .submitted }
        } while ContinuousClock.now < deadline
        return .pending(alive: alive)
    }

    enum Steadiness: Equatable { case holding(PaneObservation), released, restless }

    /// Before the retry: the text must still be held at the cursor, unchanged for `quiet` (`holding`). `released`:
    /// the target took the first Enter late (the text left the cursor on two looks in a row). `restless`: the pane
    /// never held still within the confirm limit, or could not be read.
    static func steadiness(_ timing: TmuxSubmitTiming, tail: PayloadTail, observe: Observe) async -> Steadiness {
        let deadline = ContinuousClock.now.advanced(by: timing.confirmLimit)
        var steady: (PaneObservation, ContinuousClock.Instant)?
        var released = 0
        while ContinuousClock.now < deadline {
            guard let current = await observe() else { return .restless }
            switch current.input(tail) {
            case .holding:
                released = 0
                if let (seen, since) = steady, seen == current {
                    if ContinuousClock.now - since >= timing.quiet { return .holding(current) }
                } else {
                    steady = (current, .now)
                }
            case .clear, .lineEnded:
                released += 1
                if released >= 2 { return .released }
            }
            try? await Task.sleep(for: timing.pollInterval)
        }
        return .restless
    }
}

extension TmuxAdapter {
    /// Sends the Enter and decides the outcome from what the pane shows at the cursor. Text held there for the whole
    /// confirm window gets one more Enter only if the pane changed meanwhile (identity re-checked first); an
    /// unchanged pane gets none. Still held in a live pane after the retry fails the delivery (taint).
    func attemptSubmit(
        _ session: Session, target: String, tail: PayloadTail, acceptance: TmuxSubmitProbe.Acceptance
    ) async throws -> TmuxSubmitOutcome {
        let enter = ["send-keys", "-t", session.paneID, "Enter"]
        try await tmux(enter, failure: AdapterError.deliveryFailed)
        let observe: TmuxSubmitProbe.Observe = { await self.observePane(session.paneID) }
        let before: PaneObservation?
        switch acceptance {
        case .blank, .unreadable: return .unverifiable
        case .timedOut: before = nil
        case .accepted(let seen): before = seen
        }
        let wasHolding = before?.input(tail) == .holding
        // Neither seen at the cursor before nor provably gone after: the Enter went out, nothing more is known.
        let undecided: TmuxSubmitOutcome = acceptance == .timedOut ? .unsettled : .unverifiable
        let first = await TmuxSubmitProbe.reaction(
            submitTiming, tail: tail, before: before, wasHolding: wasHolding, observe: observe
        )
        switch first {
        case .submitted: return wasHolding ? .confirmed : undecided
        case .ambiguous, .unreadable, .pending(alive: false): return undecided
        case .pending(alive: true):
            let late: TmuxSubmitOutcome = wasHolding ? .confirmed : undecided
            return try await retry(session, target: target, tail: tail, if: (late, undecided), observe: observe)
        }
    }

    /// The one retry, once the live pane holds the text steady again; otherwise the outcome for a target that took
    /// the first Enter late (`late`) or a pane that never held still (`restless`).
    private func retry(
        _ session: Session, target: String, tail: PayloadTail,
        if outcomes: (late: TmuxSubmitOutcome, restless: TmuxSubmitOutcome), observe: TmuxSubmitProbe.Observe
    ) async throws -> TmuxSubmitOutcome {
        let steady: PaneObservation
        switch await TmuxSubmitProbe.steadiness(submitTiming, tail: tail, observe: observe) {
        case .released: return outcomes.late
        case .restless: return outcomes.restless
        case .holding(let seen): steady = seen
        }
        _ = try await verified(target, binding: session.binding)
        try await tmux(["send-keys", "-t", session.paneID, "Enter"], failure: AdapterError.deliveryFailed)
        let reaction = await TmuxSubmitProbe.reaction(
            submitTiming, tail: tail, before: steady, wasHolding: true, observe: observe
        )
        switch reaction {
        case .submitted: return .retried
        case .ambiguous, .unreadable, .pending(alive: false): return .unverifiable
        case .pending(alive: true):
            throw AdapterError.deliveryFailed("the Enter was not observed to submit the text in \(target)")
        }
    }

    /// The first of `tails` pending at the cursor in `seen` (#304). A tail before a column-0 cursor after a full row
    /// counts only if tmux joins that row into the cursor row (`-J`): a soft wrap, as readline leaves for input that
    /// exactly fills the width, and never a completed line (`cat`, a shell after Enter). Unreadable: pending.
    func pendingIndex(_ seen: PaneObservation, _ tails: [PayloadTail?], in paneID: String) async -> Int? {
        for (index, tail) in tails.enumerated() where seen.pending(tail) {
            if seen.input(tail) == .holding { return index }
            let rows = ["capture-pane", "-p", "-J", "-t", paneID, "-S", "\(seen.cursorY - 1)", "-E", "\(seen.cursorY)"]
            let joined = try? await runner.run(tmuxPath, Self.baseArguments(socket: socket) + rows)
            guard let joined, joined.exitCode == 0 else { return index }
            if joined.stdout.split(separator: "\n", omittingEmptySubsequences: false).count <= 2 { return index }
        }
        return nil
    }
}
