import Foundation
import Testing
@testable import HailDaemonKit

/// Enrolled speakers, roles and unbounded stream time (#188 items 2 and 5).
extension RightyoInputConsumerTests {
    func start(speakers: String) throws -> RightyoInputEvent {
        try event("session", sequence: 1, extra: ["phase": "started", "capabilities": [
            "activation": "finalized-turn", "partials": false, "speakers": speakers, "context": true
        ]])
    }

    func roleTurn(_ id: String, role: String?, start: Int, end: Int) -> [String: Any] {
        var body = turn(id, start: start, end: end)
        if let role { body["role"] = role }
        return body
    }

    /// Transcript, attention and request at twenty minutes of stream time, far beyond the old cap.
    func lateRequest(_ consumer: RightyoInputConsumer, role: String?, decisionRole: String?,
                     priors: [[String: Any]] = []) async throws -> RightyoInputEvent {
        let at = 1_200_100
        var sequence = 2
        for prior in priors {
            _ = try await consumer.consume(event("transcript", sequence: sequence,
                                                 extra: ["turn": prior, "emitted_at_ms": at]))
            sequence += 1
        }
        let final = roleTurn("request", role: role, start: 1_199_000, end: 1_200_000)
        var decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1"]
        if let decisionRole { decision["role"] = decisionRole }
        _ = try await consumer.consume(event("transcript", sequence: sequence,
                                             extra: ["turn": final, "emitted_at_ms": at]))
        _ = try await consumer.consume(event("attention", sequence: sequence + 1, extra: [
            "utterance_id": "request", "request_id": "\(session):request", "decision": decision, "emitted_at_ms": at
        ]))
        return try event("request", sequence: sequence + 2, extra: [
            "request_id": "\(session):request", "turn": final, "decision": decision, "context": ["turns": priors],
            "decision_at_ms": at, "emitted_at_ms": at
        ])
    }

    func delivered(_ adapter: FakeAdapter) async throws -> [String: Any] {
        let text = try #require(await adapter.deliveries.first?.text)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func enrolledSessionCarriesRolesIntoPromptBeyondFifteenMinutes() async throws {
        let (consumer, adapter) = try await rig()
        #expect(try await !consumer.consume(start(speakers: "enrolled")))
        let prior = roleTurn("earlier", role: "participant", start: 1_195_000, end: 1_196_000)
        let attended = try await lateRequest(consumer, role: "owner", decisionRole: "owner", priors: [prior])
        #expect(try await consumer.consume(attended))
        let body = try await delivered(adapter)
        #expect(body["speakers"] as? String == "enrolled")
        #expect((body["request"] as? [String: Any])?["role"] as? String == "owner")
        #expect((body["decision"] as? [String: Any])?["role"] as? String == "owner")
        let turns = try #require((body["context"] as? [String: Any])?["turns"] as? [[String: Any]])
        #expect(turns.first?["role"] as? String == "participant")
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func anonymousSessionStillDeliversAtTwentyMinutesWithoutRoles() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        let attended = try await lateRequest(consumer, role: nil, decisionRole: "unknown")
        #expect(try await consumer.consume(attended))
        let body = try await delivered(adapter)
        #expect(body["speakers"] as? String == "anonymous")
        #expect((body["request"] as? [String: Any])?["role"] == nil)
        #expect((body["decision"] as? [String: Any])?["role"] as? String == "unknown")
        _ = try await consumer.consume(event("session", sequence: 6, extra: [
            "phase": "stopped", "emitted_at_ms": 86_400_000
        ]))
        try await consumer.finish()
    }

    @Test func anonymousSessionRefusesNamedRolesOnTurnsAndDecisions() async throws {
        for role in ["owner", "trusted", "participant"] {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start())
            await #expect(throws: RightyoInputError.invalidEvent) {
                try await consumer.consume(event("transcript", sequence: 2, extra: [
                    "turn": roleTurn("request", role: role, start: 1000, end: 1800)
                ]))
            }
            #expect(await adapter.deliveries.isEmpty)
            let (other, second) = try await rig()
            _ = try await other.consume(start())
            _ = try await other.consume(event("transcript", sequence: 2, extra: ["turn": turn()]))
            await #expect(throws: RightyoInputError.invalidEvent) {
                try await other.consume(event("attention", sequence: 3, extra: ["utterance_id": "request",
                    "decision": ["label": "ignore", "recipient_kind": "other_human", "confidence": 1.0,
                                 "provider": "mock", "model": "fake", "role": role]]))
            }
            #expect(await second.deliveries.isEmpty)
        }
    }

    @Test func unknownSpeakersCapabilityAndUnknownRoleValuesRefuse() async throws {
        for speakers in ["verified", "Enrolled", "", "known_speaker"] {
            let (consumer, adapter) = try await rig()
            await #expect(throws: RightyoInputError.invalidEvent) {
                try await consumer.consume(start(speakers: speakers))
            }
            await #expect(throws: RightyoInputError.invalidLifecycle) { try await consumer.consume(request()) }
            #expect(await adapter.deliveries.isEmpty)
        }
        for role in ["admin", "Owner", "", "system"] {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start(speakers: "enrolled"))
            await #expect(throws: RightyoInputError.invalidEvent) {
                try await consumer.consume(event("transcript", sequence: 2, extra: [
                    "turn": roleTurn("request", role: role, start: 1000, end: 1800)
                ]))
            }
            #expect(await adapter.deliveries.isEmpty)
        }
    }

    @Test func knownSpeakerRequestsStayRefusedEvenWhenEnrolled() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start(speakers: "enrolled"))
        let owner = roleTurn("request", role: "owner", start: 1000, end: 1800)
        _ = try await consumer.consume(event("transcript", sequence: 2, extra: ["turn": owner]))
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(event("attention", sequence: 3, extra: ["utterance_id": "request",
                "request_id": "\(session):request",
                "decision": ["label": "attend", "recipient_kind": "known_speaker", "confidence": 0.9,
                             "provider": "authored", "model": "fake-v1", "role": "owner"]]))
        }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func explicitStreamBudgetIsTheOnlyCeilingAndMustBeNonNegative() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "demo", binding: "original")])
        let host = try await HostSendTests().host(adapter)
        #expect(throws: RightyoInputError.unavailableBinding) {
            try RightyoInputConsumer(host: host, target: "tmux:demo", binding: "original", session: session,
                                     streamBudgetMs: -1)
        }
        let budgeted = try RightyoInputConsumer(host: host, target: "tmux:demo", binding: "original", session: session,
                                                allowSynthetic: true, streamBudgetMs: 900_000)
        _ = try await budgeted.consume(start())
        _ = try await budgeted.consume(event("transcript", sequence: 2,
                                             extra: ["turn": turn(), "emitted_at_ms": 900_000]))
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await budgeted.consume(event("attention", sequence: 3, extra: ["utterance_id": "request",
                "emitted_at_ms": 900_001,
                "decision": ["label": "ignore", "recipient_kind": "other_human", "confidence": 1.0,
                             "provider": "mock", "model": "fake"]]))
        }
        #expect(await adapter.deliveries.isEmpty)
        let (unbounded, other) = try await rig()
        _ = try await unbounded.consume(start())
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await unbounded.consume(event("transcript", sequence: 2, extra: ["turn": turn(), "emitted_at_ms": -1]))
        }
        #expect(await other.deliveries.isEmpty)
    }

    @Test func enrolledFixtureValidatesWithoutTargetAndDeliversWithOne() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/rightyo/enrolled-speakers.jsonl")
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        let dry = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run", session: "enrolled-demo")
        var requests = 0
        for line in lines { requests += try await dry.consume(RightyoInputEvent.decode(Data(line.utf8))) ? 1 : 0 }
        #expect(requests == 1)
        try await dry.finish()
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "demo", binding: "original")])
        let host = try await HostSendTests().host(adapter)
        let live = try RightyoInputConsumer(host: host, target: "tmux:demo", binding: "original",
                                            session: "enrolled-demo", allowSynthetic: true)
        for line in lines { _ = try await live.consume(RightyoInputEvent.decode(Data(line.utf8))) }
        let body = try await delivered(adapter)
        #expect(body["speakers"] as? String == "enrolled")
        #expect((body["request"] as? [String: Any])?["role"] as? String == "owner")
        #expect((body["request"] as? [String: Any])?["end_ms"] as? Int == 1_200_000)
        let turns = try #require((body["context"] as? [String: Any])?["turns"] as? [[String: Any]])
        #expect(turns.first?["role"] as? String == "participant")
    }
}
