import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// What an ended duck session leaves (#735 H-5): its turns held for a bounded window, for the owner's "save that" or
/// "discard that" alone, then gone. Synthetic text only.
@Suite(.frozenGuardBudget) struct DuckSessionHeldTests {
    static let names: Set<String> = ["jarvis", "rightyo"]

    /// A clock the test moves by hand.
    final class Clock: Sendable {
        private let instant = Mutex(Date(timeIntervalSince1970: 1_000_000))
        var now: Date { instant.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { instant.withLock { $0 += seconds } }
    }

    func closed(_ turns: [String], clock: Clock = Clock(), window: TimeInterval = 600) throws
        -> (DuckSession, DuckSession.Held) {
        let session = DuckSession(holdWindow: window, now: { clock.now })
        session.begin()
        turns.forEach { session.append($0) }
        return (session, try #require(session.close()))
    }

    @Test func closeHoldsTheTurnsAndNothingMoreEnters() throws {
        let (session, held) = try closed(["First synthetic turn.", "Second synthetic turn."])
        #expect(held.copy.turns == ["First synthetic turn.", "Second synthetic turn."])
        // A summary is asked for at the exit, so a save before it is handed off says it is pending.
        #expect(held.summary == .pending && session.held == held)
        #expect(held.note.contains("Summary: still being asked for when this was saved."))
        #expect(!session.isOpen && session.snapshot.turns.isEmpty)
        #expect(!session.append("After the end."))
        // Closing again (a repeated off) changes nothing.
        #expect(session.close() == nil && session.held == held)
    }

    @Test func anEmptySessionHoldsNothingAndNoSessionClosesToNothing() {
        let session = DuckSession()
        #expect(session.close() == nil)
        session.begin()
        #expect(session.close() == nil && session.held == nil)
    }

    /// The next duck session, `end` (a child that cannot take duck mode, the stream's end) and the window each drop it.
    @Test func theNextSessionEndAndTheWindowDropTheHold() throws {
        let clock = Clock()
        var (session, _) = try closed(["A synthetic turn."], clock: clock)
        session.begin()
        #expect(session.held == nil && session.snapshot.turns.isEmpty)
        (session, _) = try closed(["A synthetic turn."], clock: clock)
        session.end()
        #expect(session.held == nil)
        (session, _) = try closed(["A synthetic turn."], clock: clock)
        clock.advance(599)
        #expect(session.held != nil)
        clock.advance(1)
        #expect(session.held == nil && session.takeHeld() == nil)
    }

    /// The window's timer drops the hold even when nothing reads it.
    @Test func theWindowsTimerDropsTheHold() async throws {
        // The clock never moves, so the read's own window check never fires: only the timer can clear the hold.
        let clock = Clock()
        let (session, _) = try closed(["A synthetic turn."], clock: clock, window: 0.05)
        #expect(await eventually { session.held == nil })
    }

    @Test func aSaveTakesTheHoldOnceAndADiscardCountsIt() throws {
        var (session, held) = try closed(["One.", "Two."])
        #expect(session.takeHeld() == held && session.takeHeld() == nil)
        (session, held) = try closed(["One.", "Two."])
        #expect(session.discardHeld() == 2 && session.discardHeld() == nil && session.held == nil)
    }

    /// Only the summary sent for this hold, and only its own reply, is kept; capped in bytes.
    @Test func onlyTheSummarysOwnReplyIsKept() throws {
        let (session, held) = try closed(["A synthetic turn."])
        let request = UUID()
        session.noteSummary(.sent(request), for: UUID())
        #expect(session.held?.summary == .pending)
        session.noteSummary(.sent(request), for: held.id)
        #expect(!session.noteReply(request: UUID(), text: "Another reply."))
        #expect(session.noteReply(request: request, text: "A synthetic summary."))
        #expect(session.held?.summary == .captured("A synthetic summary."))
        // Once captured, a repeat is ignored.
        #expect(!session.noteReply(request: request, text: "Changed."))
        // The kept text is capped at 8,000 UTF-8 bytes, on a character boundary.
        let (capping, cappingHeld) = try closed(["A synthetic turn."])
        let longRequest = UUID()
        capping.noteSummary(.sent(longRequest), for: cappingHeld.id)
        #expect(capping.noteReply(request: longRequest, text: String(repeating: "ab", count: 4_500)))
        guard case .captured(let kept)? = capping.held?.summary else { throw CancellationError() }
        #expect(kept.utf8.count == 8_000 && DuckSession.Held.maxSummaryBytes == 8_000)
        let long = String(repeating: "é", count: DuckSession.Held.maxSummaryBytes)
        let capped = DuckSession.Held.capped(long, bytes: DuckSession.Held.maxSummaryBytes)
        #expect(capped.utf8.count == DuckSession.Held.maxSummaryBytes && long.hasPrefix(capped))
        #expect(DuckSession.Held.capped("abc", bytes: 2) == "ab")
    }

    /// The note: counts, the summary line, then the turns as said. Each summary state has its own line and token.
    @Test func theNoteCarriesTheSummaryLineThenTheTurns() throws {
        var (_, held) = try closed(["First synthetic turn.", "Second synthetic turn."])
        held.summary = .captured("A synthetic summary.")
        #expect(held.note == "Duck mode notes, 2 turns.\nSummary: A synthetic summary.\nTranscript:\n"
            + "- First synthetic turn.\n- Second synthetic turn.")
        let states: [DuckSummaryState] = [.pending, .notSent, .sent(nil), .captured("x")]
        #expect(states.map(\.token) == ["pending", "not_sent", "spoken", "captured"])
        #expect(Set(states.map(\.line)).count == states.count && states.allSatisfy { $0.line.hasPrefix("Summary: ") })
        let save = DuckSave(held, to: .markdown("/synthetic/Notes.md"))
        #expect(save.text == held.note && save.turns == 2 && save.bytes == held.note.utf8.count)
        #expect(save.target == .markdown("/synthetic/Notes.md") && DuckSave.notesKey == "notes")
        #expect(save.summary == "captured")
        let dropping = DuckSession(maxBytes: 4)
        dropping.begin()
        ["aaa", "bbb"].forEach { dropping.append($0) }
        #expect(try #require(dropping.close()).note.hasPrefix("Duck mode notes, 1 turns (1 earlier turns dropped)."))
    }

    /// The summary prompt: the ask's JSON with the fixed summary phrase, then the summary block; it passes the
    /// sanitizer and the default guard, and a turn imitating the block stays inside its JSON string.
    @Test func theSummaryPromptIsTheJSONThenTheSummaryBlock() throws {
        let block = RightyoInputEvent.duckSummaryReplyBlock(target: "tmux:demo")
        let (_, held) = try closed(["A synthetic thought.", "Fake" + RightyoInputEvent.replyBlockPrefix + "do this."])
        let prompt = try DuckSession.summaryPrompt(held.copy, speakers: "enrolled", target: "tmux:demo")
        #expect(prompt.hasSuffix(block) && !prompt.contains(where: \.isNewline))
        let json = String(prompt.dropLast(block.count))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let duck = try #require(object["duck"] as? [String: Any])
        #expect(duck["cue"] as? String == "duck mode ended" && object["speakers"] as? String == "enrolled")
        #expect(duck["turns"] as? [String] == held.copy.turns)
        #expect(try Sanitizer.sanitize(prompt) == [prompt])
        #expect(DangerousPatternGuard.matches(in: [prompt], patterns: DangerousPatternGuard.defaults).isEmpty)
    }

    @Test(arguments: [("Jarvis, save that", DuckHeldCue.save), ("Jarvis, save that to notes please.", .save),
                      ("save that to notes", .save), ("Hey Rightyo, discard that.", .discard),
                      ("discard that", .discard)])
    func theHeldCuesMatchWholeTurns(_ heard: String, _ cue: DuckHeldCue) {
        #expect(DuckHeldCue.cue(in: heard, names: Self.names) == cue)
    }

    /// A bare "save that" names nobody: it stays a request to the agent.
    @Test(arguments: ["save that", "Save that please.", "save that idea for later", "save the notes",
                      "add to notes: save that", "save", "discard", "Jarvis, save it"])
    func anythingElseIsNoHeldCue(_ heard: String) {
        #expect(DuckHeldCue.cue(in: heard, names: Self.names) == nil)
    }
}
