import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The end-of-session summary and the owner's save in the consumer (#735 H-5): one summary dispatch for an ended
/// session's turns, and the owner's "save that" or "discard that" while they are held. Synthetic text only.
extension RightyoInputConsumerTests {
    /// Whether duck mode is on, as the host's wish says; the test turns it off to end the session.
    final class DuckWish: Sendable {
        private let on = Mutex(true)
        var active: Bool { on.withLock { $0 } }
        func set(_ value: Bool) { on.withLock { $0 = value } }
    }

    /// A ducking consumer that has buffered `words` and then ended its session: the consumer, its session, the hold
    /// and the next free sequence.
    struct EndedDuck {
        let consumer: RightyoInputConsumer, session: DuckSession, held: DuckSession.Held?, next: Int
    }

    func endedDuck(_ words: [String], dispatcher: any RightyoDispatching = RecordingDispatcher(),
                   activation: String = "finalized-turn") async throws -> EndedDuck {
        let session = DuckSession(), wish = DuckWish()
        session.begin()
        let consumer = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original",
                                                session: self.session, allowSynthetic: true, dispatcher: dispatcher,
                                                mediaCommands: true, duckActive: { wish.active },
                                                duckSession: session)
        _ = try await consumer.consume(duckStart(activation: activation))
        let next = try await say(words, to: consumer)
        wish.set(false)
        return EndedDuck(consumer: consumer, session: session, held: session.close(), next: next)
    }

    /// The owner's (or `role`'s) whole request for `text` from `sequence`: its transcript, attention and request, as a
    /// RightyO out of duck mode sends them. Whether the consumer delivered it.
    func ownerRequest(_ text: String, to consumer: RightyoInputConsumer, at sequence: Int,
                      role: String = "owner") async throws -> Bool {
        let body = duckTurnBody(text, sequence: sequence, role: role)
        _ = try await consumer.consume(event("transcript", sequence: sequence, extra: ["turn": body]))
        let decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1", "role": role]
        _ = try await consumer.consume(event("attention", sequence: sequence + 1, extra: [
            "utterance_id": "u\(sequence)", "request_id": "\(session):u\(sequence)", "decision": decision
        ]))
        return try await consumer.consume(event("request", sequence: sequence + 2, extra: [
            "request_id": "\(session):u\(sequence)", "turn": body, "decision": decision, "context": ["turns": []],
            "decision_at_ms": sequence * 10 + 9
        ]))
    }

    @Test func theSummaryIsSentOnceThroughTheGivenStepWithTheSummaryBlock() async throws {
        let own = RecordingDispatcher(), request = UUID()
        let step = RecordingDispatcher(receipt: .init(request: request))
        let ended = try await endedDuck(["First synthetic thought.", "Second one."], dispatcher: own)
        let (consumer, session, held) = (ended.consumer, ended.session, ended.held)
        let hold = try #require(held)
        #expect(await consumer.summarizeDuck(hold, via: step) == .sent(turns: 2, bytes: hold.copy.bytes))
        let calls = await step.calls
        #expect(calls.count == 1 && calls.first?.target == "tmux:demo" && calls.first?.binding == "original")
        let text = try #require(calls.first?.text)
        let block = RightyoInputEvent.duckSummaryReplyBlock(target: "tmux:demo")
        #expect(text.hasSuffix(block) && text.contains("First synthetic thought.") && text.contains("Second one."))
        // The consumer's own step (the acknowledging one) is never used, and the hold remembers the reply request.
        #expect(await own.calls.isEmpty)
        #expect(session.held?.summary == .sent(request))
    }

    /// A stream that never sends, an anonymous one, a validation-only consumer and an ended stream send nothing.
    @Test func theSummaryIsSkippedWhereNothingMaySend() async throws {
        let step = RecordingDispatcher()
        let disabled = try await endedDuck(["A synthetic thought."], activation: "disabled").consumer
        let hold = DuckSession.Held(id: UUID(), copy: .init(turns: ["A synthetic thought."]), until: .distantFuture)
        #expect(await disabled.summarizeDuck(hold, via: step) == .skipped)
        let anonymous = try anonymousDuck(DuckSession(), dispatcher: RecordingDispatcher())
        _ = try await anonymous.consume(start())
        #expect(await anonymous.summarizeDuck(hold, via: step) == .skipped)
        let validating = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original",
                                                  session: session, duckActive: { false }, duckSession: DuckSession())
        _ = try await validating.consume(duckStart())
        #expect(await validating.summarizeDuck(hold, via: step) == .skipped)
        let ended = try await endedDuck(["A synthetic thought."])
        _ = try await ended.consumer.consume(event("session", sequence: ended.next, extra: ["phase": "stopped"]))
        #expect(await ended.consumer.summarizeDuck(hold, via: step) == .skipped)
        #expect(await step.calls.isEmpty)
    }

    /// H-3's refusal split: a guard or policy refusal is `notSent` and the stream goes on; anything else ends it.
    @Test(arguments: [(LocalDispatchRefusal.confirmationRequired, false), (.capacityExceeded, false),
                      (.connectionEnded, true), (.targetNotSelected, true)])
    func aRefusedSummaryKeepsTheStreamOnlyForGuardAndPolicy(_ refusal: LocalDispatchRefusal, _ ends: Bool)
        async throws {
        let ended = try await endedDuck(["A synthetic thought."])
        let (consumer, session, held, next) = (ended.consumer, ended.session, ended.held, ended.next)
        let outcome = await consumer.summarizeDuck(try #require(held), via: RecordingDispatcher(refusal: refusal))
        #expect(outcome == (ends ? .failed : .notSent))
        #expect(session.held?.summary == .notSent)
        let line = try duckTurn("Another synthetic line.", sequence: next)
        if ends {
            await #expect(throws: RightyoInputError.invalidLifecycle) { try await consumer.consume(line) }
        } else {
            #expect(try await !consumer.consume(line))
        }
    }

    /// The owner's "save that" takes the hold, sends nothing and leaves the note for the host; a second is a request.
    @Test func theOwnersSaveTakesTheHoldOnce() async throws {
        let dispatcher = RecordingDispatcher()
        let ended = try await endedDuck(["A synthetic thought."], dispatcher: dispatcher)
        let (consumer, session, held, next) = (ended.consumer, ended.session, ended.held, ended.next)
        #expect(try await !ownerRequest("Rightyo, save that to notes.", to: consumer, at: next))
        let save = try #require(await consumer.lastDuckSave)
        #expect(save == DuckSave(try #require(held)) && save.text.contains("- A synthetic thought."))
        #expect(await dispatcher.calls.isEmpty && session.held == nil)
        // Nothing is held any more: the same words are an ordinary request.
        #expect(try await ownerRequest("Rightyo, save that.", to: consumer, at: next + 3))
        #expect(await consumer.lastDuckSave == nil)
        #expect(await dispatcher.calls.count == 1)
    }

    @Test func theOwnersDiscardDropsTheHold() async throws {
        let dispatcher = RecordingDispatcher()
        let ended = try await endedDuck(["One.", "Two."], dispatcher: dispatcher)
        let (consumer, session, next) = (ended.consumer, ended.session, ended.next)
        #expect(try await !ownerRequest("Discard that.", to: consumer, at: next))
        #expect(await consumer.lastDuckCue == .discarded(turns: 2))
        #expect(await dispatcher.calls.isEmpty && session.held == nil)
    }

    /// A guest's save is a request like any other, and the hold stays for the owner.
    @Test func aGuestsSaveIsAnOrdinaryRequest() async throws {
        let dispatcher = RecordingDispatcher()
        let ended = try await endedDuck(["A synthetic thought."], dispatcher: dispatcher)
        let (consumer, session, next) = (ended.consumer, ended.session, ended.next)
        #expect(try await ownerRequest("Save that.", to: consumer, at: next, role: "participant"))
        #expect(await consumer.lastDuckSave == nil && session.held != nil)
        #expect(await dispatcher.calls.count == 1)
    }

    /// Without a hold (duck mode never used), "save that" and "discard that" reach the agent as before.
    @Test func withoutAHoldTheCuesAreOrdinaryRequests() async throws {
        let dispatcher = RecordingDispatcher()
        let ended = try await endedDuck([], dispatcher: dispatcher)
        let (consumer, next) = (ended.consumer, ended.next)
        #expect(ended.held == nil)
        #expect(try await ownerRequest("Save that.", to: consumer, at: next))
        #expect(try await ownerRequest("Discard that.", to: consumer, at: next + 3))
        #expect(await consumer.lastDuckSave == nil)
        #expect(await consumer.lastDuckCue == nil)
        #expect(await dispatcher.calls.count == 2)
    }

    /// On an anonymous session nobody can be told apart, so there is never a save.
    @Test func anAnonymousSessionNeverSaves() async throws {
        let session = DuckSession(), dispatcher = RecordingDispatcher()
        session.begin()
        session.append("A synthetic thought.")
        _ = session.close()
        let consumer = try anonymousDuck(session, dispatcher: dispatcher)
        _ = try await consumer.consume(start())
        var body = turn()
        body["text"] = "Save that."
        #expect(try await consumer.consume(preparedRequest(consumer, customTurn: body)))
        #expect(await consumer.lastDuckSave == nil && session.held != nil)
        #expect(await dispatcher.calls.count == 1)
    }

    func anonymousDuck(_ session: DuckSession, dispatcher: RecordingDispatcher) throws -> RightyoInputConsumer {
        try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original", session: self.session,
                                 allowSynthetic: true, dispatcher: dispatcher, duckActive: { false },
                                 duckSession: session)
    }
}
