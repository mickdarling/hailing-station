import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The duck mode buffer and cue table (#735 H-3). Synthetic text only.
@Suite(.frozenGuardBudget) struct DuckSessionTests {
    static let names: Set<String> = ["jarvis", "rightyo"]

    @Test func turnsEnterOnlyWhileASessionIsOpenAndEndDiscardsThem() {
        let session = DuckSession()
        #expect(!session.append("Before any session.") && session.snapshot.turns.isEmpty)
        session.begin()
        #expect(session.append("First synthetic turn.") && session.append("Second synthetic turn."))
        #expect(session.snapshot.turns == ["First synthetic turn.", "Second synthetic turn."])
        #expect(!session.append(""))
        session.end()
        #expect(session.snapshot == DuckSession.Snapshot() && !session.isOpen)
        #expect(!session.append("After the session."))
    }

    /// The next session starts empty: whatever the last one held is discarded at `begin`.
    @Test func aNewSessionDiscardsTheLastOne() {
        let session = DuckSession()
        session.begin()
        session.append("Old synthetic turn.")
        session.begin()
        #expect(session.snapshot.turns.isEmpty && session.isOpen)
    }

    @Test func theOldestTurnsDropAtTheByteCap() {
        let session = DuckSession(maxBytes: 20)
        session.begin()
        for text in ["aaaaaaaa", "bbbbbbbb", "cccccccc"] { session.append(text) }
        let snapshot = session.snapshot
        #expect(snapshot.turns == ["bbbbbbbb", "cccccccc"] && snapshot.bytes == 16 && snapshot.dropped == 1)
        // A turn larger than the cap alone leaves nothing rather than overflow it.
        session.append(String(repeating: "d", count: 21))
        #expect(session.snapshot.turns.isEmpty && session.snapshot.bytes == 0)
    }

    @Test func discardEmptiesTheTurnsButKeepsTheSessionOpen() {
        let times = [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 160)]
        let clock = Clock(times)
        let session = DuckSession(now: { clock.next() })
        session.begin()
        session.append("A synthetic turn.")
        #expect(session.snapshot.lastSpeech == times[1])
        #expect(session.discard() == 1)
        let snapshot = session.snapshot
        #expect(snapshot.turns.isEmpty && snapshot.started == times[0] && snapshot.lastSpeech == nil)
        #expect(session.append("Still open."))
    }

    @Test(arguments: [
        ("what do you think", DuckCue.think), ("Jarvis, what do you think?", .think),
        ("Hey Jarvis, play that back please.", .playBack), ("Play that back", .playBack),
        ("Okay Righty O, discard that.", .discard), ("Jarvis, are you still listening?", .status),
        ("please discard that", .discard)
    ])
    func aWholeTurnCueIsRecognisedNamedOrNot(_ heard: String, _ cue: DuckCue) {
        #expect(DuckCue.cue(in: heard, names: Self.names) == cue)
    }

    @Test(arguments: [
        "what do you think about the roof", "so what do you think", "Siri, what do you think", "don't discard that",
        "Jarvis, mute", "Jarvis, done thinking", "", "Jarvis"
    ])
    func anythingElseIsNoCue(_ heard: String) {
        #expect(DuckCue.cue(in: heard, names: Self.names) == nil)
    }

    /// The table matches rightyo#237's `DUCK_CUES`, less "mute", which is `VoiceMute`'s.
    @Test func theCuesAreRightyosListLessMute() {
        let rightyo: Set<String> = ["what do you think", "play that back", "mute", "are you still listening",
                                    "discard that"]
        #expect(Set(DuckCue.phrases.keys) == rightyo.subtracting(["mute"]))
        #expect(VoiceMute.command(in: "mute", names: []) == .mute)
    }

    /// The prompt is one line: JSON carrying the fixed cue phrase and the turns as strings, then the duck block; it
    /// passes the host sanitizer and the default guard.
    @Test func thePromptIsTheBufferAsJSONThenTheDuckBlock() throws {
        let clock = Clock([Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 1_090)])
        let session = DuckSession(now: { clock.next() })
        session.begin()
        session.append("A synthetic thought with \"quotes\".")
        let prompt = try session.prompt(cue: .playBack, speakers: "enrolled", target: "tmux:demo")
        let block = RightyoInputEvent.duckReplyBlock(target: "tmux:demo")
        #expect(prompt.hasSuffix(block) && !prompt.contains(where: \.isNewline))
        let json = Data(prompt.dropLast(block.count).utf8)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["speakers"] as? String == "enrolled")
        let duck = try #require(object["duck"] as? [String: Any])
        #expect(duck["cue"] as? String == "play that back")
        #expect(duck["turns"] as? [String] == ["A synthetic thought with \"quotes\"."])
        #expect(duck["started_at_ms"] as? Int == 1_000_000 && duck["last_speech_at_ms"] as? Int == 1_090_000)
        #expect(duck["dropped_turns"] as? Int == 0)
        #expect(try Sanitizer.sanitize(prompt) == [prompt])
        #expect(DangerousPatternGuard.matches(in: [prompt], patterns: DangerousPatternGuard.defaults).isEmpty)
    }

    /// A full buffer still fits the local dispatch cap with room to spare.
    @Test func aFullBufferFitsTheDispatchCap() throws {
        let session = DuckSession()
        session.begin()
        for _ in 0..<200 { session.append(String(repeating: "\"word\" ", count: 40)) }
        let prompt = try session.prompt(cue: .think, speakers: "enrolled", target: "tmux:demo")
        #expect(session.snapshot.bytes <= DuckSession.defaultMaxBytes)
        #expect(prompt.utf8.count <= LocalDispatchRequest.maxTextBytes)
    }
}

/// Hands out the given instants in turn, then repeats the last.
private final class Clock: Sendable {
    private let times: [Date]
    private let index = Mutex(0)
    init(_ times: [Date]) { self.times = times }
    func next() -> Date {
        index.withLock { index in
            defer { index += 1 }
            return times[min(index, times.count - 1)]
        }
    }
}
