#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The duck mode buffer and ask cues through the ambient pipeline (#735 H-3): under rightyo R-2 a ducking RightyO
/// sends the owner's turns as transcripts only, and the host buffers them and acts on whole-turn cues. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckBufferTests {
    /// One finalized transcript line of `text` at `sequence` (session `formed-demo`, rewritten by the script).
    static func transcript(_ text: String, sequence: Int, role: String = "owner") throws -> String {
        let at = 2_000 + sequence * 100
        let turn: [String: Any] = [
            "end_ms": at, "finalized": true, "overlap": false, "provenance": "synthetic",
            "recognizer_id": "authored-fixture", "revision": 1, "role": role, "session_id": "formed-demo",
            "speaker_id": "Speaker A", "speaker_provenance": "authored-fixture", "start_ms": at - 50, "text": text,
            "utterance_id": "duck-\(sequence)"
        ]
        let line: [String: Any] = ["emitted_at_ms": at, "schema_version": 1, "sequence": sequence,
                                   "session_id": "formed-demo", "turn": turn, "type": "transcript"]
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    /// An enrolled `started` naming `Rightyo`, advertising `duck` when `advertises`, then `words` as the owner's
    /// transcripts (each `(text, role)`), then `stopped` once the audio ends.
    static func events(_ words: [(String, String)], advertises: Bool = true) throws -> String {
        let duck = advertises ? #""duck": {"version": 1}, "# : ""
        let started = #"{"addressing": {"names": ["Rightyo"]}, "capabilities": {"activation": "finalized-turn", "#
            + #""context": true, "partials": false, "speakers": "enrolled"}, \#(duck)"emitted_at_ms": 0, "#
            + #""phase": "started", "schema_version": 1, "sequence": 1, "session_id": "formed-demo", "#
            + #""type": "session"}"#
        let lines = try words.enumerated().map { try transcript($0.element.0, sequence: $0.offset + 2,
                                                                role: $0.element.1) }
        let stopped = #"{"emitted_at_ms": 9000, "phase": "stopped", "schema_version": 1, "sequence": 99, "#
            + #""session_id": "formed-demo", "type": "session"}"#
        return ([started] + lines + [stopped]).joined(separator: "\n") + "\n"
    }

    static let script = """
    /usr/bin/sed -e '$d' -e "s/formed-demo/$7/g" events.jsonl
    /bin/cat > /dev/null
    /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
    """

    struct Seen {
        var requests: [LocalDispatchRequest] = []
        var cues: [DuckCueOutcome] = []
        var mutes: [Bool] = []
        var acknowledged = 0
        var unsupported = 0
        var delivered = 0
    }

    private func run(_ words: [(String, String)], ducking: Bool = true, advertises: Bool = true,
                     refusal: LocalDispatchRefusal? = nil) async throws -> Seen {
        let fake = try FakeRightyo(Self.script)
        defer { fake.cleanUp() }
        try Data(Self.events(words, advertises: advertises).utf8)
            .write(to: fake.directory.appendingPathComponent("events.jsonl"))
        let seen = Mutex(Seen())
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            onAcknowledge: { _ in seen.withLock { $0.acknowledged += 1 } }
        )
        configuration.replyControl = true
        configuration.onVoiceDuck = { _ in }
        configuration.onDuckCue = { outcome in seen.withLock { $0.cues.append(outcome) } }
        configuration.onVoiceMute = { on in seen.withLock { $0.mutes.append(on) } }
        configuration.onDuckUnsupported = { seen.withLock { $0.unsupported += 1 } }
        let dispatcher = RecordingAmbientDispatcher(refusal: refusal)
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        if ducking { pipeline.reportDuck(true) }
        pipeline.finishInput()
        let delivered = try await pipeline.run().delivered
        let requests = await dispatcher.requests
        return seen.withLock { seen in
            (seen.requests, seen.delivered) = (requests, delivered)
            return seen
        }
    }

    @Test func anAskSendsTheBufferOnceAndIsAcknowledged() async throws {
        let seen = try await run([("First synthetic thought.", "owner"), ("Guest synthetic words.", "participant"),
                                  ("Second synthetic thought.", "owner"), ("Rightyo, what do you think?", "owner")])
        #expect(seen.requests.count == 1 && seen.acknowledged == 1 && seen.delivered == 0)
        let request = try #require(seen.requests.first)
        #expect(request.target == "tmux:demo" && request.binding == "pinned")
        #expect(request.text.hasSuffix(RightyoInputEvent.duckReplyBlock(target: "tmux:demo")))
        #expect(request.text.contains("First synthetic thought.") && request.text.contains("Second synthetic thought."))
        #expect(!request.text.contains("Guest synthetic words.") && !request.text.contains("Rightyo, what"))
        let bytes = "First synthetic thought.Second synthetic thought.".utf8.count
        #expect(seen.cues == [.asked(turns: 2, bytes: bytes)])
    }

    @Test func discardThatEmptiesTheBufferBeforeTheNextAsk() async throws {
        let seen = try await run([("Old synthetic thought.", "owner"), ("Discard that.", "owner"),
                                  ("New synthetic thought.", "owner"), ("Play that back.", "owner")])
        let text = try #require(seen.requests.first?.text)
        #expect(seen.requests.count == 1 && !text.contains("Old synthetic") && text.contains("New synthetic"))
        #expect(seen.cues.first == .discarded(turns: 1) && seen.cues.count == 2)
    }

    /// "Mute" while ducking is the spoken mute (#404): handed to the host, never sent or buffered.
    @Test func muteWhileDuckingIsTheVoiceMute() async throws {
        let seen = try await run([("Mute.", "owner"), ("What do you think?", "owner")])
        #expect(seen.mutes == [true] && seen.acknowledged == 1)
        let text = try #require(seen.requests.first?.text)
        #expect(!text.contains("Mute."))
    }

    /// A refused ask keeps listening: the owner is told, and nothing ends the stream.
    @Test func aRefusedAskIsReportedAndTheStreamGoesOn() async throws {
        let seen = try await run([("A synthetic thought.", "owner"), ("What do you think?", "owner"),
                                  ("Discard that.", "owner")], refusal: .confirmationRequired)
        #expect(seen.cues == [.notSent, .discarded(turns: 1)])
    }

    /// The status cue is H-4's: nothing is sent, nothing acknowledged, and it never enters the buffer.
    @Test func theStatusCueIsNeitherSentNorBuffered() async throws {
        let seen = try await run([("Are you still listening?", "owner"), ("Play that back.", "owner")])
        #expect(seen.cues.first == .status && seen.requests.count == 1)
        #expect(!(seen.requests.first?.text.contains("listening") ?? true))
    }

    /// Duck mode off: transcripts are only transcripts, as before H-3.
    @Test func outsideDuckModeNothingIsBufferedSentOrAcknowledged() async throws {
        let seen = try await run([("A synthetic thought.", "owner"), ("What do you think?", "owner"),
                                  ("Mute.", "owner")], ducking: false)
        #expect(seen.requests.isEmpty && seen.cues.isEmpty && seen.mutes.isEmpty && seen.acknowledged == 0)
    }

    /// An older RightyO cannot take duck mode (H-2): the wish is dropped, so no cue counts and nothing is buffered.
    @Test func anOlderRightyoNeverBuffersOrCues() async throws {
        let seen = try await run([("A synthetic thought.", "owner"), ("What do you think?", "owner")],
                                 advertises: false)
        #expect(seen.unsupported == 1 && seen.requests.isEmpty && seen.cues.isEmpty && seen.acknowledged == 0)
    }

    /// The buffer follows the host's wish: a new session on the turn on, kept on a repeated on ("still on", a
    /// reload's re-report), ended on off or when the child cannot take it.
    @Test func theSessionBeginsAndEndsWithTheWish() {
        let session = DuckSession(), control = AmbientDuckControl(session: session)
        _ = control.report(true) { _ in true }
        session.append("A synthetic turn.")
        _ = control.report(true) { _ in true }
        #expect(session.isOpen && session.snapshot.turns.count == 1)
        _ = control.report(false) { _ in true }
        #expect(!session.isOpen && session.snapshot.turns.isEmpty)
        _ = control.report(true) { _ in true }
        session.append("Another synthetic turn.")
        let started = Data(#"{"type": "session", "phase": "started"}"#.utf8)
        #expect(control.observe(started: started) { _ in true })
        #expect(!session.isOpen && session.snapshot.turns.isEmpty && !control.active)
    }

    @Test func eachOutcomeHasItsClipAndCountsOnlyToken() {
        typealias Router = AmbientRightyoRouter
        #expect(Router.duckCueConfirmation(.asked(turns: 2, bytes: 40))
            == (nil, "cue=ask outcome=sent turns=2 bytes=40"))
        #expect(Router.duckCueConfirmation(.notSent) == (AmbientStopConfirmation.notSent, "cue=ask outcome=not_sent"))
        #expect(Router.duckCueConfirmation(.discarded(turns: 3))
            == (AmbientStopConfirmation.discarded, "cue=discard turns=3"))
        // H-4: the host answers the status cue itself with the "Duck mode is on." clip.
        #expect(Router.duckCueConfirmation(.status) == (AmbientStopConfirmation.duckOn, "cue=status outcome=answered"))
    }
}
#endif
