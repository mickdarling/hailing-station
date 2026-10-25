import Foundation

/// One token-only fact about a tmux delivery, for haild's error log (#894): reason tokens, counts, flags and ages,
/// never the words, a preview, or a hash of them (a one-word draft falls to a dictionary of unkeyed hashes). The
/// pane is named by an opaque ordinal per adapter (`pane=p1` for the first pane it pastes into or refuses), never
/// by its target id or tmux pane id: no error-log line names a target.
public struct TmuxDeliveryEvidence: Sendable, Equatable {
    /// `tmux_submit` or `tmux_input_pending`.
    public let event: String
    /// Space-separated `key=value` tokens.
    public let detail: String
}

/// Why a delivery was refused with text pending (#894). `staleInput`: text at the cursor did not leave within the
/// clear limit. `appeared`: text showed up at the cursor while the buffer filled. `tainted`: an earlier paste into
/// the pane never reached a known submit.
enum TmuxPendingReason: String { case staleInput = "stale_input", appeared, tainted }

/// haild's own last insert into each pane (#894), in memory only, and the evidence reported about it. No text is
/// kept beyond the tail the adapter already holds in `lastTails`: a monotonic paste time, a character count, whether
/// a submit (the Enter) followed, and its outcome. Every outcome still goes to OSLog and the submit observer (#83,
/// #304) as before; reporting never changes a delivery.
struct TmuxEvidenceLedger {
    private struct OwnInsert {
        let pastedAt: ContinuousClock.Instant
        let characters: Int
        var submitted = false
        var lastSubmit: TmuxSubmitOutcome?
    }

    private let submitObserver: (@Sendable (TmuxSubmitOutcome) -> Void)?
    private let observer: (@Sendable (TmuxDeliveryEvidence) -> Void)?
    private var inserts: [String: OwnInsert] = [:]
    private var ordinals: [String: String] = [:]

    init(
        submitObserver: (@Sendable (TmuxSubmitOutcome) -> Void)?, observer: (@Sendable (TmuxDeliveryEvidence) -> Void)?
    ) {
        (self.submitObserver, self.observer) = (submitObserver, observer)
    }

    mutating func pasted(_ text: String, into pane: String) {
        inserts[pane] = OwnInsert(pastedAt: .now, characters: text.count)
    }

    /// Every submit ends here exactly once, `failed` included; the target goes only to OSLog, redacted.
    mutating func submitted(_ outcome: TmuxSubmitOutcome, in pane: String, target: String) {
        outcome.record(target: target, observer: submitObserver)
        inserts[pane]?.submitted = true
        inserts[pane]?.lastSubmit = outcome
        let id = ordinal(pane)
        report("tmux_submit", ["pane=\(id)", "outcome=\(outcome.rawValue)"])
    }

    /// `seen`: the look that found text pending (nil for a tainted pane, refused without a look); `own`: the tail of
    /// haild's last insert there. `own_insert` is true when that tail itself, not a placeholder, ends at the cursor,
    /// or for a taint, which only haild's own paste sets; `pending_chars` is then that insert's length, and `none`
    /// otherwise (haild knows the length of no other text). The `own_` fields describe the last insert regardless.
    mutating func inputPending(
        _ reason: TmuxPendingReason, in pane: String, seen: PaneObservation?, own tail: PayloadTail?
    ) {
        let insert = inserts[pane]
        let own = seen.map { look in tail.map(look.endsInTail) ?? false } ?? (insert != nil)
        let age = insert.map { String((ContinuousClock.now - $0.pastedAt).components.seconds) }
        let id = ordinal(pane)
        report("tmux_input_pending", [
            "reason=\(reason.rawValue)", "pane=\(id)",
            "pending_chars=\((own ? insert?.characters : nil).map(String.init) ?? "none")",
            "placeholder=\(seen.map { String($0.input(nil) != .clear) } ?? "none")",
            "own_insert=\(own)", "own_age_s=\(age ?? "none")",
            "own_submitted=\(insert.map { String($0.submitted) } ?? "none")",
            "last_submit=\(insert?.lastSubmit?.rawValue ?? "none")"
        ])
    }

    private mutating func ordinal(_ pane: String) -> String {
        if let known = ordinals[pane] { return known }
        let next = "p\(ordinals.count + 1)"
        ordinals[pane] = next
        return next
    }

    private func report(_ event: String, _ fields: [String]) {
        observer?(TmuxDeliveryEvidence(event: event, detail: fields.joined(separator: " ")))
    }
}

extension PaneObservation {
    /// Whether `tail` itself (not a paste placeholder) ends at the cursor, under either reading of the cursor row.
    func endsInTail(_ tail: PayloadTail) -> Bool {
        let count = tail.scalars.count
        return count > 0 && [1, 2].contains { width in
            scalarsBeforeCursor(atLeast: count, unknownWidth: width).suffix(count).elementsEqual(tail.scalars)
        }
    }
}
