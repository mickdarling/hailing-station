import Foundation
import Testing
@testable import HailDaemonKit

/// Owner override (#188 item 3). Roles live in RightyoInputSpeakersTests.swift.
extension RightyoInputConsumerTests {
    /// Owner transcript and attention for utterance `override`, then the `override` event superseding `superseding`.
    /// `turnRole` is the cited transcript's role and `decisionRole` the cited attention record's role.
    func ownerOverride(_ consumer: RightyoInputConsumer, sequence: Int, superseding: String, role: String? = "owner",
                       turnRole: String? = "owner", decisionRole: String? = "owner", by: String = "override",
                       at: Int = 1_201_000) async throws -> RightyoInputEvent {
        _ = try await consumer.consume(event("transcript", sequence: sequence, extra: [
            "turn": roleTurn("override", role: turnRole, start: at - 500, end: at), "emitted_at_ms": at
        ]))
        var decision: [String: Any] = ["label": "uncertain", "recipient_kind": "unknown", "confidence": 0.5,
                                       "provider": "authored", "model": "fake-v1"]
        if let decisionRole { decision["role"] = decisionRole }
        _ = try await consumer.consume(event("attention", sequence: sequence + 1, extra: [
            "utterance_id": "override", "decision": decision, "emitted_at_ms": at
        ]))
        var body: [String: Any] = ["superseded_request_id": superseding, "by_utterance_id": by, "emitted_at_ms": at]
        if let role { body["role"] = role }
        return try event("override", sequence: sequence + 2, extra: body)
    }

    @Test func ownerOverrideAfterDeliveredRequestIsRecordedWithoutNewDeliveryOrRollback() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start(speakers: "enrolled"))
        let attended = try await lateRequest(consumer, role: "participant", decisionRole: "participant")
        #expect(try await consumer.consume(attended))
        let override = try await ownerOverride(consumer, sequence: 5, superseding: "\(session):request")
        #expect(try await consumer.consume(override))
        #expect(try await !consumer.consume(override))
        #expect(try await !consumer.consume(attended))
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func anonymousSessionRefusesOverrideAndFailsClosed() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        let override = try await ownerOverride(consumer, sequence: 2, superseding: "\(session):request",
                                               turnRole: nil, decisionRole: nil, at: 2000)
        await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(override) }
        await #expect(throws: RightyoInputError.invalidLifecycle) { try await consumer.consume(request(sequence: 5)) }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func overrideWithoutOwnerRoleIsRefused() async throws {
        for role in ["trusted", "participant", "unknown", "Owner", nil] {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start(speakers: "enrolled"))
            let override = try await ownerOverride(consumer, sequence: 2, superseding: "\(session):request", role: role)
            await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(override) }
            #expect(await adapter.deliveries.isEmpty)
        }
    }

    /// The cited utterance's admitted transcript must have carried `role: owner`; a participant, trusted, unknown
    /// or absent role on an enrolled session is refused (fail closed) even though the override itself says `owner`.
    @Test func overrideCitingNonOwnerOrRolelessTranscriptIsRefused() async throws {
        for cited in ["participant", "trusted", "unknown", nil] {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start(speakers: "enrolled"))
            let override = try await ownerOverride(consumer, sequence: 2, superseding: "\(session):request",
                                                   turnRole: cited, decisionRole: cited)
            await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(override) }
            #expect(await adapter.deliveries.isEmpty)
        }
    }

    /// Both admitted records must say `owner`: an owner transcript whose attention record carries another role, or
    /// none, is refused, and a non-owner transcript is never promoted by an owner attention record.
    @Test func overrideCitingRecordsThatDisagreeOnOwnerRoleIsRefused() async throws {
        let mismatches: [(turn: String?, decision: String?)] = [("owner", "participant"), ("owner", nil),
                                                                 ("participant", "owner"), (nil, "owner")]
        for pair in mismatches {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start(speakers: "enrolled"))
            let override = try await ownerOverride(consumer, sequence: 2, superseding: "\(session):request",
                                                   turnRole: pair.turn, decisionRole: pair.decision)
            await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(override) }
            #expect(await adapter.deliveries.isEmpty)
        }
    }

    @Test func laterRequestNamedByAnEarlierOverrideIsRefused() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start(speakers: "enrolled"))
        #expect(try await consumer.consume(ownerOverride(consumer, sequence: 2, superseding: "\(session):request",
                                                          at: 3000)))
        let final = turn("request", start: 3500, end: 4000)
        let decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1"]
        _ = try await consumer.consume(event("transcript", sequence: 5, extra: ["turn": final, "emitted_at_ms": 4000]))
        _ = try await consumer.consume(event("attention", sequence: 6, extra: [
            "utterance_id": "request", "request_id": "\(session):request", "decision": decision, "emitted_at_ms": 4100
        ]))
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(event("request", sequence: 7, extra: [
                "request_id": "\(session):request", "turn": final, "decision": decision, "context": ["turns": []],
                "decision_at_ms": 4100, "emitted_at_ms": 4100
            ]))
        }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func unknownSupersededRequestIsAdmittedIdempotentlyAndSessionContinues() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start(speakers: "enrolled"))
        let unknown = "\(session):never-admitted"
        #expect(try await consumer.consume(ownerOverride(consumer, sequence: 2, superseding: unknown)))
        let again = try event("override", sequence: 5, extra: [
            "superseded_request_id": unknown, "by_utterance_id": "override", "role": "owner",
            "emitted_at_ms": 1_201_000
        ])
        #expect(try await consumer.consume(again))
        _ = try await consumer.consume(event("session", sequence: 6, extra: ["phase": "stopped",
                                                                             "emitted_at_ms": 1_201_000]))
        try await consumer.finish()
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func malformedOverrideFieldsAndStrayFieldsOnOtherEventsRefuse() async throws {
        let cases: [(superseding: String, by: String)] = [
            ("other:request", "override"), ("\(session):bad/id", "override"), ("request", "override"),
            ("\(session):", "override"), ("\(session):request", "ghost"), ("\(session):request", "bad/id")
        ]
        for item in cases {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(start(speakers: "enrolled"))
            let override = try await ownerOverride(consumer, sequence: 2, superseding: item.superseding, by: item.by)
            await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(override) }
            #expect(await adapter.deliveries.isEmpty)
        }
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start(speakers: "enrolled"))
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(event("transcript", sequence: 2, extra: [
                "turn": roleTurn("request", role: "owner", start: 1000, end: 1800),
                "superseded_request_id": "\(session):request"
            ]))
        }
        #expect(await adapter.deliveries.isEmpty)
    }

    /// With a real host the fixture's non-owner request trips the dangerous-pattern guard and is refused as
    /// `confirmationRequired` before the override arrives: roles and overrides never bypass the guard.
    @Test func overrideFixtureValidatesWithoutTargetAndTheGuardStillRefusesWithOne() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/rightyo/enrolled-override.jsonl")
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        let dry = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run", session: "enrolled-demo")
        var requests = 0, overrides = 0
        for line in lines {
            let event = try RightyoInputEvent.decode(Data(line.utf8))
            guard try await dry.consume(event) else { continue }
            if event.supersededRequestId == "enrolled-demo:request" { overrides += 1 } else { requests += 1 }
        }
        #expect(requests == 1 && overrides == 1)
        try await dry.finish()
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "demo", binding: "original")])
        let host = try await HostSendTests().host(adapter)
        let live = try RightyoInputConsumer(host: host, target: "tmux:demo", binding: "original",
                                            session: "enrolled-demo", allowSynthetic: true)
        var refused = 0
        for line in lines {
            do { _ = try await live.consume(RightyoInputEvent.decode(Data(line.utf8))) } catch
                RightyoInputError.confirmationRequired { refused += 1 } catch RightyoInputError.invalidLifecycle {}
        }
        #expect(refused == 1)
        #expect(await adapter.deliveries.isEmpty)
    }
}
