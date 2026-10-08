import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct RightyoInputConsumerTests {
    let session = "tool-demo"

    func event(_ type: String, sequence: Int, extra: [String: Any] = [:]) throws -> RightyoInputEvent {
        var body: [String: Any] = ["schema_version": 1, "type": type, "session_id": session,
                                  "sequence": sequence, "emitted_at_ms": 2000]
        body.merge(extra) { _, value in value }
        return try RightyoInputEvent.decode(JSONSerialization.data(withJSONObject: body))
    }

    func start() throws -> RightyoInputEvent {
        try event("session", sequence: 1, extra: ["phase": "started", "capabilities": [
            "activation": "finalized-turn", "partials": false, "speakers": "anonymous", "context": true
        ]])
    }

    func turn(_ id: String = "request", start: Int = 1000, end: Int = 1800) -> [String: Any] {
        ["session_id": session, "utterance_id": id, "revision": 1, "start_ms": start, "end_ms": end,
         "text": "Please summarize our discussion.", "speaker_id": "Speaker A", "finalized": true,
         "overlap": false, "recognizer_id": "authored", "provenance": "synthetic",
         "speaker_provenance": "authored-fixture"]
    }

    func request(sequence: Int = 2, turns: [[String: Any]] = []) throws -> RightyoInputEvent {
        try event("request", sequence: sequence, extra: ["request_id": "\(session):request", "turn": turn(),
            "decision": ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                         "provider": "authored", "model": "fake-v1"],
            "context": ["turns": turns], "decision_at_ms": 1900])
    }

    func preparedRequest(_ consumer: RightyoInputConsumer, turns: [[String: Any]] = [],
                         customTurn: [String: Any]? = nil) async throws -> RightyoInputEvent {
        var sequence = 2
        for prior in turns {
            _ = try await consumer.consume(event("transcript", sequence: sequence, extra: ["turn": prior]))
            sequence += 1
        }
        let final = customTurn ?? turn()
        let decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1"]
        _ = try await consumer.consume(event("transcript", sequence: sequence, extra: ["turn": final]))
        _ = try await consumer.consume(event("attention", sequence: sequence + 1,
            extra: ["utterance_id": "request", "request_id": "\(session):request", "decision": decision]))
        return try event("request", sequence: sequence + 2, extra: ["request_id": "\(session):request", "turn": final,
            "decision": decision, "context": ["turns": turns], "decision_at_ms": 1900])
    }

    func rig(tier: Tier = .open, allowSynthetic: Bool = true) async throws -> (RightyoInputConsumer, FakeAdapter) {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "demo", binding: "original")])
        let host = try await HostSendTests().host(adapter, tier: tier)
        let consumer = try RightyoInputConsumer(host: host, target: "tmux:demo", binding: "original", session: session,
                                                allowSynthetic: allowSynthetic)
        return (consumer, adapter)
    }

    @Test func finalizedRequestDeliversCompleteTextAndDiarizedContextOnce() async throws {
        let (consumer, adapter) = try await rig()
        #expect(try await !consumer.consume(start()))
        let prior = turn("earlier", start: 100, end: 900)
        let attended = try await preparedRequest(consumer, turns: [prior])
        #expect(try await consumer.consume(attended))
        #expect(try await !consumer.consume(attended))
        let deliveries = await adapter.deliveries
        #expect(deliveries.count == 1)
        let data = try Data(promptBody(#require(deliveries.first?.text)).utf8)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = try #require(decoded["context"] as? [String: Any])
        #expect((context["turns"] as? [[String: Any]])?.first?["speaker_id"] as? String == "Speaker A")
        #expect(deliveries.first?.binding == "original")
    }

    @Test func transcriptAndAttentionNeverDispatchAndGapsAreAllowed() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        _ = try await consumer.consume(event("transcript", sequence: 4, extra: ["turn": turn()]))
        _ = try await consumer.consume(event("attention", sequence: 7, extra: ["utterance_id": "request",
            "decision": ["label": "ignore", "recipient_kind": "other_human", "confidence": 1.0,
                         "provider": "mock", "model": "fake"]]))
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func missingStartUnknownVersionForeignSessionAndStaleSequenceRefuse() async throws {
        let (missing, first) = try await rig()
        await #expect(throws: RightyoInputError.invalidLifecycle) { try await missing.consume(request()) }
        #expect(await first.deliveries.isEmpty)
        for change in [["schema_version": 2], ["session_id": "foreign"], ["emitted_at_ms": -1]] {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start())
            await #expect(throws: RightyoInputError.invalidEvent) {
                try await consumer.consume(event("attention", sequence: 2, extra: change))
            }
            await #expect(throws: RightyoInputError.invalidLifecycle) {
                try await consumer.consume(request(sequence: 3))
            }
            #expect(await adapter.deliveries.isEmpty)
        }
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        _ = try await consumer.consume(event("transcript", sequence: 5, extra: ["turn": turn()]))
        await #expect(throws: RightyoInputError.sequenceGap) {
            try await consumer.consume(event("attention", sequence: 3))
        }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func terminalCancelStopErrorRefuseLaterRequests() async throws {
        for phase in ["cancelled", "stopped", "error"] {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start())
            _ = try await consumer.consume(event("session", sequence: 2, extra: ["phase": phase]))
            await #expect(throws: RightyoInputError.invalidLifecycle) {
                try await consumer.consume(request(sequence: 3))
            }
            #expect(await adapter.deliveries.isEmpty)
        }
    }

    @Test func futureContextAndOversizedLinesAreRefused() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(request(turns: [turn("future", start: 1200, end: 1300)]))
        }
        #expect(throws: RightyoInputError.capacity) {
            try RightyoInputEvent.decode(Data(repeating: 32, count: 1_200_001))
        }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func targetReplacementAndConfirmationRefuseWithoutRetry() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        await adapter.setTargets([AdapterTarget(name: "demo", binding: "replacement")])
        await #expect(throws: HostError.denied(.rebound("tmux:demo"))) {
            try await consumer.consume(preparedRequest(consumer))
        }
        #expect(await adapter.deliveries.isEmpty)
        let (confirmed, other) = try await rig(tier: .confirm)
        _ = try await confirmed.consume(start())
        let attended = try await preparedRequest(confirmed)
        await #expect(throws: RightyoInputError.confirmationRequired) { try await confirmed.consume(attended) }
        #expect(try await !confirmed.consume(attended))
        #expect(await other.deliveries.isEmpty)
    }
}
