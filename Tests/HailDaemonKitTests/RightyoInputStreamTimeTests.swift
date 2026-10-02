import Foundation
import Testing
@testable import HailDaemonKit

/// No default stream-time ceiling and the optional explicit budget (#188 item 5).
extension RightyoInputConsumerTests {
    @Test func anonymousSessionStillDeliversAtTwentyMinutesWithoutRoles() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        let attended = try await lateRequest(consumer, role: nil, decisionRole: "unknown")
        #expect(try await consumer.consume(attended))
        let body = try await delivered(adapter)
        #expect(body["speakers"] as? String == "anonymous")
        #expect((body["request"] as? [String: Any])?["role"] == nil)
        #expect((body["decision"] as? [String: Any])?["role"] as? String == "unknown")
        _ = try await consumer.consume(event("session", sequence: 6,
                                             extra: ["phase": "stopped", "emitted_at_ms": 86_400_000]))
        try await consumer.finish()
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
}
