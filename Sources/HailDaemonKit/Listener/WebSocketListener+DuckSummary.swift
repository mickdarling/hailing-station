#if os(macOS)
import Foundation

/// Duck mode's end (#735 H-5): the summary's outcome, its spoken text kept for a save, and the owner's "save that".
extension AmbientRightyoRouter {
    /// The summary dispatch's outcome for `connection`, in order: a guard or policy refusal plays `confirm-not-sent/`
    /// so the owner knows no summary is coming; a sent summary needs no clip (its reply follows), nor does one that
    /// failed (the stream ends) or was skipped. Logs counts and tokens only, never words.
    func duckSummary(on connection: UUID, listener: WebSocketListener) -> @Sendable (DuckSummaryOutcome) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] outcome in
            chain.enqueue { [weak self, weak listener] in
                let (persona, detail) = Self.duckSummaryConfirmation(outcome)
                var confirm = "none"
                if let persona {
                    confirm = await self?.confirmVoiceMute(persona, on: connection, listener: listener) ?? "none"
                }
                self?.emit("ambient_duck_summary", connection: connection, detail: "\(detail) confirm=\(confirm)")
            }
        }
    }

    /// The clip folder that answers a summary outcome, or nil for none, and the log token for what happened.
    static func duckSummaryConfirmation(_ outcome: DuckSummaryOutcome) -> (String?, String) {
        switch outcome {
        case .sent(let turns, let bytes): (nil, "outcome=sent turns=\(turns) bytes=\(bytes)")
        case .notSent: (AmbientStopConfirmation.notSent, "outcome=not_sent")
        case .failed: (nil, "outcome=failed")
        case .skipped: (nil, "outcome=skipped")
        }
    }

    /// The owner's "save that" (#735 H-5): the note goes to the owner's allowlisted `notes` destination (#552) by
    /// `VoiceNoteRunner`, and only there: the consumer resolved `save.target` from `notes` alone, and without one it
    /// was never a save. Then `confirm-saved/` or `confirm-not-saved/`, one at a time, in the order said. Logs the
    /// destination, outcome, counts, the summary's state token and the clip; never the words.
    func duckSave(on connection: UUID, listener: WebSocketListener) -> @Sendable (DuckSave) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] save in
            chain.enqueue { [weak self, weak listener] in
                guard let self else { return }
                let outcome = await configuration.notes.run(save.target, text: save.text)
                let persona = outcome == "saved" ? AmbientStopConfirmation.saved : AmbientStopConfirmation.notSaved
                let confirm = await confirmVoiceMute(persona, on: connection, listener: listener)
                let detail = "destination=notes outcome=\(outcome) turns=\(save.turns) bytes=\(save.bytes)"
                emit("ambient_duck_save", connection: connection,
                     detail: "\(detail) summary=\(save.summary) confirm=\(confirm)")
            }
        }
    }
}
#endif
