import Foundation

// The duck cue tables (moved here from DuckSession.swift, unchanged but for `spoken`, to keep that file in its length
// limit) and what an ended duck session leaves for the owner (#735 H-5).

/// What the owner's duck cue did (#735 H-3), for the host to confirm and log: counts only, never words. `asked` was
/// handed to the agent with that many buffered turns and bytes; `notSent` was refused before handoff (nothing went
/// anywhere, the buffer stays); `discarded` emptied that many turns; `status` is H-4's to answer.
public enum DuckCueOutcome: Sendable, Equatable {
    case asked(turns: Int, bytes: Int)
    case notSent
    case discarded(turns: Int)
    case status
}

/// The owner's short cues while ducking (#735 H-3): whole turns, named or not ("what do you think?", "Jarvis, play
/// that back"), trimmed as `VoiceDuck` trims. RightyO releases the same phrases alone while ducking (rightyo#237
/// `DUCK_CUES`, with "mute", which is `VoiceMute`'s); keep the two lists in step. Matched on the heard words only.
enum DuckCue: Sendable, Equatable {
    /// "What do you think": the agent asks or offers one brief thought from the buffer.
    case think
    /// "Play that back": the agent recaps the buffer briefly.
    case playBack
    /// "Discard that": the buffer is emptied; nothing is sent.
    case discard
    /// "Are you still listening": H-4's status cue. Matched so it is never buffered or sent; H-4 answers it.
    case status

    static let all: [DuckCue] = [.think, .playBack, .discard, .status]
    static let phrases = Dictionary(uniqueKeysWithValues: all.map { ($0.phrase, $0) })

    /// The fixed phrase the prompt names, never the heard words.
    var phrase: String {
        switch self {
        case .think: "what do you think"
        case .playBack: "play that back"
        case .discard: "discard that"
        case .status: "are you still listening"
        }
    }

    /// The cue a whole turn says, given the session's keyed addressing `names`; nil for anything else.
    static func cue(in heard: String, names: Set<String>) -> DuckCue? { phrases[spoken(heard, names: names).words] }

    /// A whole turn's words, lowercased and space-joined, without a greeting, the assistant's name or "please", and
    /// whether it named the assistant (`VoiceMute.nameWidth`, the rule `VoiceDuck` uses).
    static func spoken(_ heard: String, names: Set<String>) -> (words: String, named: Bool) {
        var words = heard.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)[...]
        while words.last == "please" { words.removeLast() }
        if let first = words.first, VoiceMute.greetings.contains(first) { words = words.dropFirst() }
        let named = VoiceMute.nameWidth(words, names: names)
        if let named { words = words.dropFirst(named) }
        if words.first == "please" { words = words.dropFirst() }
        return (words.joined(separator: " "), named != nil)
    }
}

/// The owner's cues for an ended session's held turns (#735 H-5), trimmed as `DuckCue` trims. Commands only while a
/// hold lasts; otherwise each is a request like any other, as before duck mode existed.
enum DuckHeldCue: Sendable, Equatable {
    /// "Save that to notes", named or not, or "<name>, save that": the held turns and summary go to the owner's
    /// `notes` destination. A bare "save that" is too common a phrase to act on: it stays a request to the agent.
    case save
    /// "Discard that": the held turns and summary go, unsaved.
    case discard

    static func cue(in heard: String, names: Set<String>) -> DuckHeldCue? {
        let (words, named) = DuckCue.spoken(heard, names: names)
        switch words {
        case "save that to notes": return .save
        case "save that": return named ? .save : nil
        case "discard that": return .discard
        default: return nil
        }
    }
}

/// What became of an ended session's summary (#735 H-5). Every hold asks for one (an exit without a summary discards
/// the turns instead). `pending`: asked for at the exit, not yet handed off. `notSent`: skipped, refused or failed.
/// `sent`: handed to the agent as that input request (nil when the target owns no reply). `captured`: that reply's
/// spoken text, as the host delivered it. The text is never logged; `token` is.
enum DuckSummaryState: Sendable, Equatable {
    case pending, notSent
    case sent(UUID?)
    case captured(String)

    var token: String {
        switch self {
        case .pending: "pending"
        case .notSent: "not_sent"
        case .sent: "spoken"
        case .captured: "captured"
        }
    }

    /// The note's summary line: the spoken text when the host saw it, otherwise what happened to it.
    var line: String {
        switch self {
        case .captured(let text): "Summary: " + text
        case .sent: "Summary: spoken aloud; its text did not reach the host."
        case .pending: "Summary: still being asked for when this was saved."
        case .notSent: "Summary: none; the request was not sent."
        }
    }
}

/// What the summary dispatch did (#735 H-5), for the host to log: counts only. `sent` was handed to the agent with that
/// many turns and bytes; `notSent` was refused by the guard or policy before handoff; `failed` met any other failure,
/// which ends the stream as a request's would; `skipped` sent nothing (no delivery step, or a stream that never sends).
public enum DuckSummaryOutcome: Sendable, Equatable {
    case sent(turns: Int, bytes: Int)
    case notSent, failed, skipped
}

/// The owner's "save that" (#735 H-5): the note, the owner's allowlisted `notes` destination it goes to, and counts
/// for the log. `text` is the owner's words and the summary: it goes only to that destination's handler, never to a
/// log.
public struct DuckSave: Sendable, Equatable {
    /// The one destination a duck save may use, keyed as the destinations file keys it.
    static let notesKey = RightyoAddressing.key("notes")

    let text: String
    let target: VoiceDestinations.Destination
    public let turns: Int
    public let bytes: Int
    /// `DuckSummaryState.token`.
    public let summary: String

    init(_ held: DuckSession.Held, to target: VoiceDestinations.Destination) {
        (text, self.target) = (held.note, target)
        (turns, bytes, summary) = (held.copy.turns.count, text.utf8.count, held.summary.token)
    }
}

extension DuckSession {
    /// What an ended session left (#735 H-5): its turns, until when they are kept, and the summary's state. `id` ties
    /// a summary's result to this hold and no later one.
    struct Held: Sendable, Equatable {
        /// The longest summary text kept for a save, in UTF-8 bytes.
        static let maxSummaryBytes = 8_000
        /// The summary prompt's fixed cue phrase.
        static let summaryPhrase = "duck mode ended"

        let id: UUID
        let copy: Snapshot
        let until: Date
        var summary = DuckSummaryState.pending

        /// What "save that" writes: a heading with the counts, the summary line, then each turn as said.
        var note: String {
            let dropped = copy.dropped > 0 ? " (\(copy.dropped) earlier turns dropped)" : ""
            let turns = copy.turns.map { "- " + $0 }.joined(separator: "\n")
            return "Duck mode notes, \(copy.turns.count) turns\(dropped).\n\(summary.line)\nTranscript:\n\(turns)"
        }

        /// `text` cut to at most `bytes` UTF-8 bytes, on a character boundary.
        static func capped(_ text: String, bytes: Int) -> String {
            var count = 0
            return String(text.prefix { character in
                count += character.utf8.count
                return count <= bytes
            })
        }
    }

    /// The summary prompt for an ended session (#735 H-5): the same JSON as an ask (`json`), naming the fixed
    /// summary phrase, then the summary reply block for `target`. The host's sanitizer and guard still run on it.
    static func summaryPrompt(_ copy: Snapshot, speakers: String, target: String) throws -> String {
        try json(copy, phrase: Held.summaryPhrase, speakers: speakers)
            + RightyoInputEvent.duckSummaryReplyBlock(target: target)
    }
}
