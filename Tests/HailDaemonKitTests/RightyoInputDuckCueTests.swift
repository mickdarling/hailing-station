import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The duck mode buffer and ask cues in the consumer (#735 H-3): while ducking, the enrolled owner's live transcript
/// turns enter the buffer, and a whole-turn cue sends it, empties it or mutes. Synthetic text only.
extension RightyoInputConsumerTests {
    /// An enrolled `started` naming `Rightyo`, as a RightyO that advertised duck mode would send it.
    func duckStart() throws -> RightyoInputEvent {
        try event("session", sequence: 1, extra: ["phase": "started", "addressing": ["names": ["Rightyo"]],
                                                  "capabilities": ["activation": "finalized-turn", "partials": false,
                                                                   "speakers": "enrolled", "context": true]])
    }

    /// One finalized transcript of `text` at `sequence`, the owner's unless `role` says otherwise.
    func duckTurn(_ text: String, sequence: Int, role: String? = "owner",
                  provenance: String = "synthetic") throws -> RightyoInputEvent {
        var body = roleTurn("u\(sequence)", role: role, start: sequence * 10, end: sequence * 10 + 5)
        (body["text"], body["provenance"]) = (text, provenance)
        return try event("transcript", sequence: sequence, extra: ["turn": body])
    }

    func duckConsumer(ducking: Bool = true, session: DuckSession? = DuckSession(),
                      dispatcher: any RightyoDispatching, allowSynthetic: Bool = true,
                      echo: (@Sendable (String) -> Bool)? = nil) throws -> RightyoInputConsumer {
        session?.begin()
        return try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original", session: self.session,
                                 allowSynthetic: allowSynthetic, dispatcher: dispatcher, echoFilter: echo,
                                 mediaCommands: true, duckActive: { ducking }, duckSession: session)
    }

    /// Feeds `words` as transcripts from sequence 2 on; the next free sequence.
    @discardableResult
    func say(_ words: [String], to consumer: RightyoInputConsumer, from sequence: Int = 2,
             role: String? = "owner") async throws -> Int {
        for (offset, text) in words.enumerated() {
            #expect(try await !consumer.consume(duckTurn(text, sequence: sequence + offset, role: role)))
        }
        return sequence + words.count
    }

    func duckBody(_ text: String) throws -> [String: Any] {
        #expect(text.hasSuffix(RightyoInputEvent.duckReplyBlock(target: "tmux:demo")))
        let json = String(text.dropLast(RightyoInputEvent.duckReplyBlock(target: "tmux:demo").count))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try #require(object["duck"] as? [String: Any])
    }

    @Test func theOwnersTurnsEnterTheBufferAndWhatDoYouThinkSendsThemOnce() async throws {
        let session = DuckSession(), dispatcher = RecordingDispatcher()
        let consumer = try duckConsumer(session: session, dispatcher: dispatcher)
        _ = try await consumer.consume(duckStart())
        let next = try await say(["First synthetic thought.", "Second synthetic thought."], to: consumer)
        #expect(session.snapshot.turns == ["First synthetic thought.", "Second synthetic thought."])
        #expect(try await consumer.consume(duckTurn("Rightyo, what do you think?", sequence: next)))
        #expect(await consumer.lastDuckCue == .asked(turns: 2, bytes: session.snapshot.bytes))
        let calls = await dispatcher.calls
        #expect(calls.count == 1 && calls.first?.target == "tmux:demo" && calls.first?.binding == "original")
        let body = try duckBody(#require(calls.first?.text))
        #expect(body["cue"] as? String == "what do you think")
        #expect(body["turns"] as? [String] == ["First synthetic thought.", "Second synthetic thought."])
        // The cue itself is not buffered, and the buffer keeps growing after it.
        try await say(["Third synthetic thought."], to: consumer, from: next + 1)
        #expect(session.snapshot.turns.count == 3)
    }

    @Test(arguments: [("play that back", "play that back"), ("Hey Rightyo, play that back please.", "play that back"),
                      ("What do you think", "what do you think")])
    func anAskCueNamedOrNotSendsItsFixedPhrase(_ heard: String, _ phrase: String) async throws {
        let dispatcher = RecordingDispatcher()
        let consumer = try duckConsumer(dispatcher: dispatcher)
        _ = try await consumer.consume(duckStart())
        let next = try await say(["A synthetic idea."], to: consumer)
        #expect(try await consumer.consume(duckTurn(heard, sequence: next)))
        let body = try duckBody(#require(await dispatcher.calls.first?.text))
        #expect(body["cue"] as? String == phrase)
    }

    /// A guest's turn, an echo of the assistant's reply and a turn not from the live microphone never enter.
    @Test func onlyTheOwnersLiveNonEchoTurnsAreBuffered() async throws {
        let session = DuckSession()
        let consumer = try duckConsumer(session: session, dispatcher: RecordingDispatcher(),
                                        echo: { $0.contains("echoed") })
        _ = try await consumer.consume(duckStart())
        var next = try await say(["Guest synthetic words."], to: consumer, role: "participant")
        next = try await say(["Unlabelled synthetic words."], to: consumer, from: next, role: nil)
        try await say(["An echoed synthetic reply.", "Owner synthetic words."], to: consumer, from: next)
        #expect(session.snapshot.turns == ["Owner synthetic words."])
        let live = DuckSession()
        let strict = try duckConsumer(session: live, dispatcher: RecordingDispatcher(), allowSynthetic: false)
        _ = try await strict.consume(duckStart())
        try await say(["Owner synthetic words."], to: strict)
        #expect(live.snapshot.turns.isEmpty)
    }

    /// A guest's cue does nothing at all: it is neither buffered nor sent.
    @Test func aGuestsCueIsIgnored() async throws {
        let session = DuckSession(), dispatcher = RecordingDispatcher()
        let consumer = try duckConsumer(session: session, dispatcher: dispatcher)
        _ = try await consumer.consume(duckStart())
        let next = try await say(["Owner synthetic words."], to: consumer)
        try await say(["What do you think?", "Discard that."], to: consumer, from: next, role: "participant")
        #expect(await dispatcher.calls.isEmpty && session.snapshot.turns == ["Owner synthetic words."])
    }

    @Test func discardThatEmptiesTheBufferAndSendsNothing() async throws {
        let session = DuckSession(), dispatcher = RecordingDispatcher()
        let consumer = try duckConsumer(session: session, dispatcher: dispatcher)
        _ = try await consumer.consume(duckStart())
        let next = try await say(["One synthetic line.", "Two synthetic lines."], to: consumer)
        #expect(try await !consumer.consume(duckTurn("Rightyo, discard that.", sequence: next)))
        #expect(await consumer.lastDuckCue == .discarded(turns: 2))
        #expect(await dispatcher.calls.isEmpty && session.snapshot.turns.isEmpty && session.isOpen)
    }

    /// "Mute" is the owner's spoken mute, carried out as `VoiceMute` is; the status cue is H-4's and does nothing yet.
    @Test func muteIsTheVoiceMuteAndTheStatusCueIsNeitherBufferedNorSent() async throws {
        let session = DuckSession(), dispatcher = RecordingDispatcher()
        let consumer = try duckConsumer(session: session, dispatcher: dispatcher)
        _ = try await consumer.consume(duckStart())
        #expect(try await !consumer.consume(duckTurn("Mute.", sequence: 2)))
        #expect(await consumer.lastVoiceMute == .mute)
        #expect(await consumer.lastDuckCue == nil)
        #expect(try await !consumer.consume(duckTurn("Rightyo, are you still listening?", sequence: 3)))
        #expect(await consumer.lastDuckCue == .status)
        #expect(await consumer.lastVoiceMute == nil)
        #expect(await dispatcher.calls.isEmpty && session.snapshot.turns.isEmpty)
    }

    /// A refusal before handoff (here the guard's) is not the end of the stream: nothing was sent, the owner is told,
    /// the buffer stays and the next event is admitted.
    @Test func aRefusedAskKeepsTheStreamAndTheBuffer() async throws {
        let session = DuckSession()
        let dispatcher = RecordingDispatcher(refusal: LocalDispatchRefusal.confirmationRequired)
        let consumer = try duckConsumer(session: session, dispatcher: dispatcher)
        _ = try await consumer.consume(duckStart())
        let next = try await say(["A synthetic line."], to: consumer)
        #expect(try await !consumer.consume(duckTurn("What do you think?", sequence: next)))
        #expect(await consumer.lastDuckCue == .notSent && session.snapshot.turns.count == 1)
        try await say(["Another synthetic line."], to: consumer, from: next + 1)
        #expect(session.snapshot.turns.count == 2)
    }

    /// Through a real host, the ask passes the host's sanitizer and default guard and is typed once, as one line.
    @Test func anAskIsDeliveredThroughTheHostsSanitizerAndGuard() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "demo", binding: "original")])
        let host = try await HostSendTests().host(adapter)
        let session = DuckSession()
        session.begin()
        let consumer = try RightyoInputConsumer(host: host, target: "tmux:demo", binding: "original",
                                                session: self.session, allowSynthetic: true, duckActive: { true },
                                                duckSession: session)
        _ = try await consumer.consume(duckStart())
        let next = try await say(["A synthetic plan with \"quotes\" and a back\\slash."], to: consumer)
        #expect(try await consumer.consume(duckTurn("Play that back.", sequence: next)))
        let deliveries = await adapter.deliveries
        #expect(deliveries.count == 1)
        let text = try #require(deliveries.first?.text)
        #expect(text.hasPrefix("{") && !text.contains(where: \.isNewline))
        #expect(try duckBody(text)["turns"] as? [String] == ["A synthetic plan with \"quotes\" and a back\\slash."])
    }
}
