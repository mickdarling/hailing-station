import Foundation
import Testing
@testable import HailDaemonKit

/// What a duck cue may never do (#735 H-3): send from a transcription-only stream, or be sent twice when a request
/// for the same utterance follows it. Synthetic text only.
extension RightyoInputConsumerTests {
    /// A stream whose `started` said `activation: "disabled"` never sends, even ducking: no ask, no buffer, no mute.
    @Test func aTranscriptionOnlyStreamNeverAsksBuffersOrMutes() async throws {
        let session = DuckSession(), dispatcher = RecordingDispatcher()
        let consumer = try duckConsumer(session: session, dispatcher: dispatcher)
        _ = try await consumer.consume(duckStart(activation: "disabled"))
        let next = try await say(["A synthetic thought.", "Mute."], to: consumer)
        #expect(await consumer.lastVoiceMute == nil)
        #expect(try await !consumer.consume(duckTurn("Rightyo, what do you think?", sequence: next)))
        #expect(await consumer.lastDuckCue == nil)
        #expect(await dispatcher.calls.isEmpty)
        #expect(session.snapshot.turns.isEmpty)
    }

    /// A request for an utterance already carried out as a cue is held back: the ask is sent once, never typed again.
    /// This is also the setup of a second child on the connection that never advertised `duck`: the host's wish is on,
    /// so its owner turns still buffer and cue, while it goes on deciding turns and sending requests.
    @Test func aRequestForACueAlreadyCarriedOutIsHeldBack() async throws {
        let dispatcher = RecordingDispatcher()
        let consumer = try duckConsumer(dispatcher: dispatcher)
        _ = try await consumer.consume(duckStart())
        let body = duckTurnBody("What do you think?", sequence: 2)
        #expect(try await consumer.consume(event("transcript", sequence: 2, extra: ["turn": body])))
        let decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1", "role": "owner"]
        _ = try await consumer.consume(event("attention", sequence: 3, extra: [
            "utterance_id": "u2", "request_id": "\(session):u2", "decision": decision
        ]))
        let request = try event("request", sequence: 4, extra: [
            "request_id": "\(session):u2", "turn": body, "decision": decision, "context": ["turns": []],
            "decision_at_ms": 1900
        ])
        #expect(try await !consumer.consume(request))
        #expect(await dispatcher.calls.count == 1)
    }

    /// A connection or selection that is gone ends the consumer, as for a request; only a guard or policy refusal
    /// keeps listening.
    @Test(arguments: [(LocalDispatchRefusal.connectionEnded, true), (.sessionNotReady, true),
                      (.targetNotSelected, true), (.confirmationRequired, false), (.capacityExceeded, false)])
    func onlyGuardAndPolicyRefusalsKeepListening(_ refusal: LocalDispatchRefusal, _ ends: Bool) async throws {
        let consumer = try duckConsumer(dispatcher: RecordingDispatcher(refusal: refusal))
        _ = try await consumer.consume(duckStart())
        let ask = try duckTurn("What do you think?", sequence: 2)
        if ends {
            await #expect(throws: refusal) { try await consumer.consume(ask) }
        } else {
            #expect(try await !consumer.consume(ask))
            #expect(await consumer.lastDuckCue == .notSent)
        }
    }
}
