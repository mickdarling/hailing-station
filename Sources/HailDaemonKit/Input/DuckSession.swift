public import Foundation
import Synchronization

/// What the owner says aloud in one duck session (#735 H-3, "let me think out loud"): the enrolled owner's own
/// transcript turns, held in RAM only so an ask cue can send them to the agent. Bounded by `maxBytes` of UTF-8 text,
/// the oldest turns dropping first. Turns enter only between `begin` and `close` (duck mode on, then off), and
/// "discard that" empties it. Nothing here is ever logged or written anywhere: callers log counts only.
/// Which turns may enter is the consumer's rule (`RightyoInputConsumer.noteDuckTurn`), not this buffer's.
/// After duck mode ends (#735 H-5) `close` keeps the turns, and the summary's state, as one `Held` for
/// `holdWindow` (ten minutes), for the owner's "save that" or "discard that" alone; the next `begin`, `end`, the
/// window's end, a save or a discard drop them. `end` drops everything at once (a child that cannot take duck mode,
/// the stream's end).
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

    /// How long an ended session's turns wait for the owner's "save that" (#735 H-5): ten minutes.
    public static let defaultHoldWindow: TimeInterval = 600

    /// The open session's turns, and what the last ended one left (#735 H-5), under one lock.
    private struct State {
        var live = Snapshot()
        var held: Held?
    }

    private let state = Mutex(State())
    private let maxBytes: Int
    private let holdWindow: TimeInterval
    private let now: @Sendable () -> Date

    public init(maxBytes: Int = DuckSession.defaultMaxBytes, holdWindow: TimeInterval = DuckSession.defaultHoldWindow,
                now: @escaping @Sendable () -> Date = { Date() }) {
        (self.maxBytes, self.holdWindow, self.now) = (max(1, maxBytes), max(0, holdWindow), now)
    }

    /// A new session (duck mode turned on): whatever the last one held, open or ended, is discarded first.
    func begin() {
        let instant = now()
        state.withLock { $0 = State(live: Snapshot(started: instant)) }
    }

    /// Everything is discarded at once, the open session's turns and an ended one's, and nothing more enters.
    func end() { state.withLock { $0 = State() } }

    /// Whether a session is open, so turns may enter.
    var isOpen: Bool { state.withLock { $0.live.started != nil } }

    /// Adds one turn while a session is open, then drops the oldest turns until the text fits; false when no session
    /// is open or the text is empty.
    @discardableResult func append(_ text: String) -> Bool {
        let instant = now()
        return state.withLock { state in
            guard state.live.started != nil, !text.isEmpty else { return false }
            state.live.turns.append(text)
            state.live.bytes += text.utf8.count
            state.live.lastSpeech = instant
            while !state.live.turns.isEmpty, state.live.bytes > maxBytes || state.live.turns.count > Self.maxTurns {
                state.live.bytes -= state.live.turns.removeFirst().utf8.count
                state.live.dropped += 1
            }
            return true
        }
    }

    /// "Discard that": the turns go, the session stays open. How many turns were discarded.
    @discardableResult func discard() -> Int {
        state.withLock { state in
            let count = state.live.turns.count
            (state.live.turns, state.live.bytes, state.live.dropped, state.live.lastSpeech) = ([], 0, 0, nil)
            return count
        }
    }

    /// The open session's turns (empty once it is closed).
    var snapshot: Snapshot { state.withLock { $0.live } }

    /// Duck mode turned off (#735 H-5): the open session closes and nothing more enters. Its turns, if any, are held
    /// for `holdWindow` as one `Held`, which is returned for the summary; nil when no session was open or it held no
    /// turn, and then nothing is held. A timer drops the hold at the window's end; every read checks it too.
    func close() -> Held? {
        let instant = now()
        let held = state.withLock { state -> Held? in
            guard state.live.started != nil else { return nil }
            let copy = state.live
            state.live = Snapshot()
            state.held = copy.turns.isEmpty ? nil : Held(id: UUID(), copy: copy, until: instant + holdWindow)
            return state.held
        }
        if let id = held?.id {
            Task { [weak self, holdWindow] in
                try? await Task.sleep(for: .seconds(holdWindow))
                self?.state.withLock { if $0.held?.id == id { $0.held = nil } }
            }
        }
        return held
    }

    /// What the last ended session left, while its window lasts; nil otherwise (an expired hold is dropped here).
    var held: Held? { state.withLock { live(&$0) } }

    /// The owner's "save that" (#735 H-5): the hold, taken so it is saved at most once; nil when nothing is held.
    func takeHeld() -> Held? {
        state.withLock { state in
            defer { state.held = nil }
            return live(&state)
        }
    }

    /// The owner's "discard that" after duck mode ended (#735 H-5): how many turns were held, or nil for none.
    func discardHeld() -> Int? { takeHeld()?.copy.turns.count }

    /// Records what became of the summary for the hold `id`; a later hold or none ignores it.
    func noteSummary(_ summary: DuckSummaryState, for id: UUID) {
        state.withLock { if $0.held?.id == id { $0.held?.summary = summary } }
    }

    /// Keeps the summary's spoken text when `request` is the reply the summary was sent as (#735 H-5), capped at
    /// `Held.maxSummaryBytes`; true when it was kept. Any other reply is ignored. Never logged.
    @discardableResult func noteReply(request: UUID, text: String) -> Bool {
        state.withLock { state in
            guard case .sent(request)? = live(&state)?.summary else { return false }
            state.held?.summary = .captured(Held.capped(text, bytes: Held.maxSummaryBytes))
            return true
        }
    }

    private func live(_ state: inout State) -> Held? {
        if let held = state.held, now() >= held.until { state.held = nil }
        return state.held
    }

    /// The prompt for an ask cue from one `snapshot` of the buffer (so what is sent and what is counted agree): it as
    /// compact JSON (the cue's fixed phrase, never the heard words; the
    /// owner's turns as JSON strings, so no turn text reaches the top level), then the duck reply block for `target`.
    /// One line; the host's sanitizer and guard still run on it at dispatch.
    static func prompt(_ copy: Snapshot, cue: DuckCue, speakers: String, target: String) throws -> String {
        try json(copy, phrase: cue.phrase, speakers: speakers) + RightyoInputEvent.duckReplyBlock(target: target)
    }

    /// The same JSON for any fixed `phrase`: an ask cue's, or the summary's (#735 H-5).
    static func json(_ copy: Snapshot, phrase: String, speakers: String) throws -> String {
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
        let millis = { (date: Date?) in date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(Prompt(duck: Body(cue: phrase, startedAtMs: millis(copy.started),
                                                        lastSpeechAtMs: millis(copy.lastSpeech), turns: copy.turns,
                                                        droppedTurns: copy.dropped),
                                             speakers: speakers))
        guard let json = String(data: data, encoding: .utf8) else { throw RightyoInputError.invalidEvent }
        return json
    }
}
