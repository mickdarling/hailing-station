import Foundation
import Testing
@testable import HailDaemonKit

extension RightyoInputConsumerTests {
    @Test func canonicalProducerFixtureAndDryRunShareTheSameContract() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/rightyo/tool-events.jsonl")
        let content = try String(contentsOf: path, encoding: .utf8)
        let consumer = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run", session: session)
        var requests = 0
        for line in content.split(separator: "\n") {
            let event = try RightyoInputEvent.decode(Data(line.utf8))
            if try await consumer.consume(event) { requests += 1 }
        }
        #expect(requests == 1)
        try await consumer.finish()
    }

    @Test func syntheticRequiresExplicitOptInAndIncompleteEOFRefuses() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "demo", binding: "original")])
        let host = try await HostSendTests().host(adapter)
        let consumer = try RightyoInputConsumer(host: host, target: "tmux:demo", binding: "original", session: session)
        _ = try await consumer.consume(start())
        await #expect(throws: RightyoInputError.invalidLifecycle) { try await consumer.finish() }
        await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(preparedRequest(consumer)) }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func localWholePromptSupportsContextBeyondLegacyCharacterCap() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "demo", binding: "original")])
        let host = try await HostSendTests().host(adapter,
            sanitizing: .init(maxCharacters: 1_200_000, maxUTF8Bytes: 1_200_000))
        let consumer = try RightyoInputConsumer(host: host, target: "tmux:demo", binding: "original", session: session,
                                                allowSynthetic: true)
        _ = try await consumer.consume(start())
        var prior = turn("earlier", start: 100, end: 900)
        prior["text"] = String(repeating: "invented discussion ", count: 150).trimmingCharacters(in: .whitespaces)
        #expect(try await consumer.consume(preparedRequest(consumer, turns: [prior])))
        #expect(await adapter.deliveries.first?.text.count ?? 0 > 2000)
    }

    @Test func changedDuplicateAndRepeatedRequestIdentityRefuse() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        _ = try await consumer.consume(preparedRequest(consumer))
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(event("attention", sequence: 4))
        }
        await #expect(throws: RightyoInputError.invalidLifecycle) { try await consumer.consume(request(sequence: 5)) }
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func lockedTargetAndDangerousPatternStillRefuse() async throws {
        let (locked, adapter) = try await rig(tier: .locked)
        _ = try await locked.consume(start())
        await #expect(throws: HostError.denied(.locked("tmux:demo"))) {
            try await locked.consume(preparedRequest(locked))
        }
        #expect(await adapter.deliveries.isEmpty)
        let (guarded, other) = try await rig()
        _ = try await guarded.consume(start())
        var dangerous = turn()
        dangerous["text"] = "rm -rf build"
        let event = try await preparedRequest(guarded, customTurn: dangerous)
        await #expect(throws: RightyoInputError.confirmationRequired) { try await guarded.consume(event) }
        #expect(await other.deliveries.isEmpty)
    }
    @Test func unknownOverlappingSpeakersStayDataAndControlsCannotHideGuardPatterns() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        var prior = turn("overlap-a", start: 100, end: 900)
        prior["speaker_id"] = NSNull()
        prior["overlap"] = true
        let second = turn("overlap-b", start: 200, end: 950)
        #expect(try await consumer.consume(preparedRequest(consumer, turns: [prior, second])))
        #expect(await adapter.deliveries.count == 1)
        let (refused, other) = try await rig()
        _ = try await refused.consume(start())
        var escaped = turn()
        escaped["text"] = "r\u{1B}[31mm -rf build"
        let event = try event("request", sequence: 2, extra: ["request_id": "\(session):request", "turn": escaped,
            "decision": ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                         "provider": "mock", "model": "fake"],
            "context": ["turns": []], "decision_at_ms": 1900])
        await #expect(throws: RightyoInputError.invalidEvent) { try await refused.consume(event) }
        #expect(await other.deliveries.isEmpty)
    }
    @Test func disabledActivationAcceptsTranscriptsAndTimeoutMetadataButNeverRequests() async throws {
        let consumer = try RightyoInputConsumer(host: nil, target: "dry", binding: "dry", session: session)
        let disabled = try event("session", sequence: 1, extra: ["phase": "started", "capabilities": [
            "activation": "disabled", "partials": false, "speakers": "anonymous", "context": true
        ]])
        _ = try await consumer.consume(disabled)
        _ = try await consumer.consume(event("transcript", sequence: 2, extra: ["turn": turn()]))
        _ = try await consumer.consume(event("session", sequence: 4, extra: [
            "phase": "error", "emitted_at_ms": 900_250
        ]))
        await #expect(throws: RightyoInputError.producerFailed) { try await consumer.finish() }
    }
    @Test func requestsWithoutMatchingImmutableFinalAndAttentionRefuse() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(request(sequence: 2)) }
        let (other, second) = try await rig()
        _ = try await other.consume(start())
        _ = try await other.consume(event("transcript", sequence: 2, extra: ["turn": turn()]))
        await #expect(throws: RightyoInputError.invalidEvent) { try await other.consume(request(sequence: 3)) }
        #expect(await adapter.deliveries.isEmpty)
        #expect(await second.deliveries.isEmpty)
    }
    @Test func canonicalCoverageMetadataSurvivesGuardedHandoff() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/rightyo/tool-events.jsonl")
        let (consumer, adapter) = try await rig()
        for line in try String(contentsOf: path, encoding: .utf8).split(separator: "\n") {
            _ = try await consumer.consume(RightyoInputEvent.decode(Data(line.utf8)))
        }
        let text = try promptBody(#require(await adapter.deliveries.first?.text))
        let body = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let context = try #require(body["context"] as? [String: Any])
        let retention = try #require(context["retention"] as? [String: Any])
        #expect(retention["cutoff_ms"] as? Int == 0)
        #expect(retention["session_turn_count"] as? Int == 1)
        #expect(retention["max_session_turns"] as? Int == 1000)
        #expect(retention["retained_bytes"] as? Int == 319)
        #expect(retention["boundary_policy"] as? String == "retain whole turns whose end exceeds cutoff")
        #expect(retention.count == 15)
    }
    @Test func laterConflictingAttentionCannotKeepOldAttendedEvidence() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        let attended = try await preparedRequest(consumer)
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(event("attention", sequence: 4, extra: ["utterance_id": "request",
                "decision": ["label": "ignore", "recipient_kind": "other_human", "confidence": 1.0,
                         "provider": "authored",
                             "model": "fake-v1"]]))
        }
        await #expect(throws: RightyoInputError.invalidLifecycle) { try await consumer.consume(attended) }
        #expect(await adapter.deliveries.isEmpty)
    }
    @Test func strictTypedProbabilityProvenanceAndIdentifierBoundsRefuse() async throws {
        for mutation: [String: Any] in [["provenance": "invented"], ["speaker_provenance": "invented"],
                                      ["recognizer_id": String(repeating: "x", count: 97)],
                                      ["speaker_id": "speaker:invalid"]] {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start())
            var invalid = turn()
            invalid.merge(mutation) { _, value in value }
            await #expect(throws: RightyoInputError.invalidEvent) {
                try await consumer.consume(event("transcript", sequence: 2, extra: ["turn": invalid]))
            }
            #expect(await adapter.deliveries.isEmpty)
        }
        for probability: Any in [NSNull(), true, -0.1, 1.1] {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start())
            _ = try await consumer.consume(event("transcript", sequence: 2, extra: ["turn": turn()]))
            await #expect(throws: RightyoInputError.invalidEvent) {
                try await consumer.consume(event("attention", sequence: 3, extra: ["utterance_id": "request",
                    "decision": ["label": "attend", "recipient_kind": "system", "confidence": probability,
                                 "provider": "mock", "model": "mock-v1"]]))
            }
            #expect(await adapter.deliveries.isEmpty)
        }
    }
}
