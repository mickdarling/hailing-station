import Foundation
import Testing
@testable import HailDaemonKit

/// Optional producer `role_status` (#188 fixture resync to RightyO main 6594c65). Overrides live in
/// RightyoInputOverrideTests.swift.
extension RightyoInputConsumerTests {
    /// RightyO main emits an optional `role_status` on session events and on the degrading turn's decision when a
    /// priority provider is configured. The consumer decodes past it and never acts on it: it is not fingerprinted,
    /// not forwarded in the prompt and does not change admission.
    @Test func roleStatusOnSessionAndDecisionIsDecodedAndIgnored() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(event("session", sequence: 1, extra: [
            "phase": "started", "role_status": "ready", "capabilities": [
                "activation": "finalized-turn", "partials": false, "speakers": "enrolled", "context": true
            ]
        ]))
        let at = 1_200_100
        let final = roleTurn("request", role: "owner", start: 1_199_000, end: 1_200_000)
        var decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1", "role": "owner"]
        _ = try await consumer.consume(event("transcript", sequence: 2, extra: ["turn": final, "emitted_at_ms": at]))
        _ = try await consumer.consume(event("attention", sequence: 3, extra: [
            "utterance_id": "request", "request_id": "\(session):request", "decision": decision, "emitted_at_ms": at
        ]))
        decision["role_status"] = "degraded"
        #expect(try await consumer.consume(event("request", sequence: 4, extra: [
            "request_id": "\(session):request", "turn": final, "decision": decision, "context": ["turns": []],
            "decision_at_ms": at, "emitted_at_ms": at
        ])))
        let body = try await delivered(adapter)
        let delivered = try #require(body["decision"] as? [String: Any])
        #expect(delivered["role"] as? String == "owner")
        #expect(delivered["role_status"] == nil)
        #expect(!(await adapter.deliveries.first?.text ?? "").contains("role_status"))
        _ = try await consumer.consume(event("session", sequence: 5, extra: [
            "phase": "stopped", "role_status": "ready", "emitted_at_ms": at
        ]))
        try await consumer.finish()
        #expect(await adapter.deliveries.count == 1)
    }
}
