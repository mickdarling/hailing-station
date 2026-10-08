import Foundation
import Testing
@testable import HailDaemonKit

/// Natural dismissal (rightyo#98) against the producer's real streams, and the ordering of the withdrawn drop.
extension RightyoInputConsumerTests {
    /// The withdrawn drop comes after the existing refusals: a repeat of a dropped id is still a duplicate, and a
    /// non-live request on a live-only consumer still ends the session (second-key review of #310).
    @Test func aRepeatedWithdrawnRequestIsStillRefusedAsADuplicate() async throws {
        let (consumer, adapter) = try await rig()
        let late = try await withdrawnLater(consumer)
        #expect(try await !consumer.consume(late(6)))
        await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(late(7)) }
        #expect(await consumer.withdrawnDropped == 1)
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func aWithdrawnSyntheticRequestStillTripsTheLiveOnlyRefusal() async throws {
        let (consumer, adapter) = try await rig(allowSynthetic: false)
        let late = try await withdrawnLater(consumer)
        await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(late(6)) }
        #expect(await consumer.withdrawnDropped == 0)
        #expect(await adapter.deliveries.isEmpty)
    }

    /// RightyO keeps `label: attend` on a turn it dismissed, withdrew or superseded, but sends no `request_id`
    /// (rightyo#98). That attention is admitted and records nothing, so no request can cite it.
    @Test func anAttendWithoutARequestIdIsAdmittedAndFormsNoRequest() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(dismissalStart())
        let final = turn("held", start: 3700, end: 4000)
        let decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1"]
        _ = try await consumer.consume(event("transcript", sequence: 2, extra: ["turn": final, "emitted_at_ms": 4000]))
        #expect(try await !consumer.consume(event("attention", sequence: 3, extra: [
            "utterance_id": "held", "decision": decision, "emitted_at_ms": 4000
        ])))
        let uncited = try event("request", sequence: 4, extra: [
            "request_id": "\(session):held", "turn": final, "decision": decision, "context": ["turns": []],
            "decision_at_ms": 4000, "emitted_at_ms": 4000
        ])
        await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(uncited) }
        #expect(await adapter.deliveries.isEmpty)
    }

    /// Streams RightyO 0abd969 emits in its own `tests/test_dismissal.py`, captured verbatim: a model-judged
    /// "Go away." with engagement and a cool-down, a late stop phrase withdrawing a pending request, and an enrolled
    /// session with two decision dismissals. Each carries an `attend` without `request_id`, which ended ambient.
    @Test(arguments: [("dismissal-producer-disengage", 1, ["decision"]),
                      ("dismissal-producer-late-withdrawal", 0, ["stop-phrase", "stop-phrase"]),
                      ("dismissal-producer-enrolled", 3, ["decision", "decision"])])
    func producerDismissalStreamsValidateDryToTheEnd(name: String, expected: Int, reasons: [String]) async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/rightyo/\(name).jsonl")
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        let dry = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run", session: "dismissal-test")
        var requests = 0, dismissals: [String] = []
        for line in lines {
            requests += try await dry.consume(RightyoInputEvent.decode(Data(line.utf8))) ? 1 : 0
            if let receipt = await dry.lastDismissal { dismissals.append(receipt.reason) }
        }
        try await dry.finish()
        #expect(requests == expected)
        #expect(dismissals == reasons)
    }
}
