public import Foundation
import Synchronization

/// What the owner says aloud in one duck session (#735 H-3, "let me think out loud"): the enrolled owner's own
/// transcript turns, held in RAM only so an ask cue can send them to the agent. Bounded by `maxBytes` of UTF-8 text,
/// the oldest turns dropping first. It holds turns only between `begin` and `end` (duck mode on, then off), and
/// "discard that" empties it. Nothing here is ever logged or written anywhere: callers log counts only.
/// Which turns may enter is the consumer's rule (`RightyoInputConsumer.noteDuckTurn`), not this buffer's.
public final class DuckSession: Sendable {
    /// About twenty minutes of steady speech. Bounded well inside the local dispatch cap, and small enough that the
    /// guard's per-rule budget (#208) is never at risk on one prompt.
    public static let defaultMaxBytes = 32_000
    static let maxTurns = 2_000

    /// One copy of the buffer: the turns in the order said, when the session began, when a turn last entered it,
    /// how many turns the cap dropped, and the turns' UTF-8 byte count.
    struct Snapshot: Sendable, Equatable {
        var turns: [String] = []
        var started: Date?
        var lastSpeech: Date?
        var dropped = 0
        var bytes = 0
    }

    private let state = Mutex(Snapshot())
    private let maxBytes: Int
    private let now: @Sendable () -> Date

    public init(maxBytes: Int = DuckSession.defaultMaxBytes, now: @escaping @Sendable () -> Date = { Date() }) {
        (self.maxBytes, self.now) = (max(1, maxBytes), now)
    }

    /// A new session (duck mode turned on): whatever the last one held is discarded first.
    func begin() {
        let instant = now()
        state.withLock { $0 = Snapshot(started: instant) }
    }

    /// The session is over (duck mode turned off, or never taken): everything is discarded and nothing more enters.
    func end() { state.withLock { $0 = Snapshot() } }

    /// Whether a session is open, so turns may enter.
    var isOpen: Bool { state.withLock { $0.started != nil } }

    /// Adds one turn while a session is open, then drops the oldest turns until the text fits; false when no session
    /// is open or the text is empty.
    @discardableResult func append(_ text: String) -> Bool {
        let instant = now()
        return state.withLock { state in
            guard state.started != nil, !text.isEmpty else { return false }
            state.turns.append(text)
            state.bytes += text.utf8.count
            state.lastSpeech = instant
            while !state.turns.isEmpty, state.bytes > maxBytes || state.turns.count > Self.maxTurns {
                state.bytes -= state.turns.removeFirst().utf8.count
                state.dropped += 1
            }
            return true
        }
    }

    /// "Discard that": the turns go, the session stays open. How many turns were discarded.
    @discardableResult func discard() -> Int {
        state.withLock { state in
            let count = state.turns.count
            (state.turns, state.bytes, state.dropped, state.lastSpeech) = ([], 0, 0, nil)
            return count
        }
    }

    var snapshot: Snapshot { state.withLock { $0 } }

    /// The prompt for an ask cue: the session as compact JSON (the cue's fixed phrase, never the heard words; the
    /// owner's turns as JSON strings, so no turn text reaches the top level), then the duck reply block for `target`.
    /// One line; the host's sanitizer and guard still run on it at dispatch.
    func prompt(cue: DuckCue, speakers: String, target: String) throws -> String {
        struct Body: Encodable {
            let cue: String
            let startedAtMs: Int64?
            let lastSpeechAtMs: Int64?
            let turns: [String]
            let droppedTurns: Int
        }
        struct Prompt: Encodable {
            let duck: Body
            let speakers: String
        }
        let copy = snapshot
        let millis = { (date: Date?) in date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(Prompt(duck: Body(cue: cue.phrase, startedAtMs: millis(copy.started),
                                                        lastSpeechAtMs: millis(copy.lastSpeech), turns: copy.turns,
                                                        droppedTurns: copy.dropped),
                                             speakers: speakers))
        guard let json = String(data: data, encoding: .utf8) else { throw RightyoInputError.invalidEvent }
        return json + RightyoInputEvent.duckReplyBlock(target: target)
    }
}

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
    static func cue(in heard: String, names: Set<String>) -> DuckCue? {
        var words = heard.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)[...]
        while words.last == "please" { words.removeLast() }
        if let first = words.first, VoiceMute.greetings.contains(first) { words = words.dropFirst() }
        if let named = VoiceMute.nameWidth(words, names: names) { words = words.dropFirst(named) }
        if words.first == "please" { words = words.dropFirst() }
        return phrases[words.joined(separator: " ")]
    }
}
