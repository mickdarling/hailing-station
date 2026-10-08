import Foundation
import Testing
@testable import HailDaemonKit

/// Natural dismissal (rightyo#98): `dismiss` is admitted only after `started` advertises `dismissal` version 1.
extension RightyoInputConsumerTests {
    static var dismissal: [String: Any] {
        ["version": 1, "window_ms": 10_000, "cooldown_ms": 30_000, "cooldown_min_confidence": 0.9]
    }

    func dismissalStart(speakers: String = "anonymous", dismissal: Any? = Self.dismissal) throws -> RightyoInputEvent {
        var extra: [String: Any] = ["phase": "started", "capabilities": [
            "activation": "finalized-turn", "partials": false, "speakers": speakers, "context": true
        ]]
        if let dismissal { extra["dismissal"] = dismissal }
        return try event("session", sequence: 1, extra: extra)
    }

    /// The transcript of the dismissing turn `stop` (3,000–3,600 ms), then its stop-phrase `dismiss` with `changes`.
    func dismiss(_ consumer: RightyoInputConsumer, sequence: Int, role: String? = nil,
                 changes: [String: Any] = [:]) async throws -> RightyoInputEvent {
        _ = try await consumer.consume(event("transcript", sequence: sequence, extra: [
            "turn": roleTurn("stop", role: role, start: 3000, end: 3600), "emitted_at_ms": 3600
        ]))
        var body: [String: Any] = ["utterance_id": "stop", "speech_end_ms": 3600, "speaker_id": "Speaker A",
                                   "scope": ["playback", "pending_request"], "withdrawn_request_ids": [String](),
                                   "reason": "stop-phrase", "confidence": NSNull(), "emitted_at_ms": 3600]
        if let role { body["role"] = role }
        body.merge(changes) { _, value in value }
        return try event("dismiss", sequence: sequence + 1, extra: body)
    }

    func stopped(_ sequence: Int) throws -> RightyoInputEvent {
        try event("session", sequence: sequence, extra: ["phase": "stopped", "emitted_at_ms": 9000])
    }

    @Test func advertisedDismissIsAdmittedDeliversNothingAndTheSessionGoesOn() async throws {
        let (consumer, adapter) = try await rig()
        #expect(try await !consumer.consume(dismissalStart()))
        let event = try await dismiss(consumer, sequence: 2)
        #expect(try await !consumer.consume(event))
        #expect(await consumer.lastDismissal == RightyoDismissReceipt(
            reason: "stop-phrase", scope: ["playback", "pending_request"], withdrawn: 0, alreadyDelivered: 0))
        // A replay is idempotent and leaves no second receipt.
        #expect(try await !consumer.consume(event))
        #expect(await consumer.lastDismissal == nil)
        _ = try await consumer.consume(stopped(4))
        try await consumer.finish()
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func dismissWithoutTheAdvertisementIsRefusedAsBefore() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(start())
        let event = try await dismiss(consumer, sequence: 2)
        await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(event) }
        await #expect(throws: RightyoInputError.invalidLifecycle) { try await consumer.consume(stopped(4)) }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func malformedOrMisplacedAdvertisementIsRefused() async throws {
        var extraKey = Self.dismissal
        extraKey["playback_active"] = true
        var missing = Self.dismissal
        missing["cooldown_ms"] = nil
        let changes: [(String, Any)] = [("version", 2), ("window_ms", 0), ("window_ms", 60_001),
                                        ("cooldown_ms", -1), ("cooldown_min_confidence", 1.5), ("version", "1")]
        var advertisements: [Any] = [NSNull(), [String: Any](), extraKey, missing, true]
        for (key, value) in changes {
            var changed = Self.dismissal
            changed[key] = value
            advertisements.append(changed)
        }
        for advertisement in advertisements {
            let (consumer, _) = try await rig()
            await #expect(throws: RightyoInputError.invalidEvent) {
                try await consumer.consume(dismissalStart(dismissal: advertisement))
            }
        }
        let (consumer, _) = try await rig()
        _ = try await consumer.consume(dismissalStart())
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(event("transcript", sequence: 2, extra: ["turn": turn(),
                                                                               "dismissal": Self.dismissal]))
        }
    }

    @Test func invalidDismissFieldsAreRefused() async throws {
        let foreign = "other-session:request"
        let tooMany = (0...RightyoInputEvent.maxWithdrawnIDs).map { "\(session):r\($0)" }
        let changes: [[String: Any]] = [
            ["scope": [String]()], ["scope": ["volume"]], ["scope": ["playback", "playback"]], ["scope": NSNull()],
            ["withdrawn_request_ids": [foreign]], ["withdrawn_request_ids": tooMany],
            ["withdrawn_request_ids": ["\(session):a", "\(session):a"]], ["withdrawn_request_ids": ["\(session):a;b"]],
            ["withdrawn_request_ids": NSNull()], ["reason": "other"], ["reason": NSNull()], ["confidence": 0.5],
            ["reason": "decision"], ["reason": "decision", "confidence": 1.5], ["speech_end_ms": 3601],
            ["speech_end_ms": -1], ["utterance_id": "ghost"], ["utterance_id": NSNull()], ["role": "owner"],
            ["speaker_id": "Speaker\nA"], ["cooldown_until_ms": 33_600],
            ["scope": ["playback", "pending_request", "engagement"], "cooldown_until_ms": 3599],
            ["turn": turn("stop", start: 3000, end: 3600)], ["request_id": "\(session):stop"]
        ]
        for change in changes {
            let (consumer, adapter) = try await rig()
            _ = try await consumer.consume(dismissalStart())
            let event = try await dismiss(consumer, sequence: 2, changes: change)
            await #expect(throws: RightyoInputError.invalidEvent, "\(change)") { try await consumer.consume(event) }
            #expect(await adapter.deliveries.isEmpty)
        }
        // Dismiss-only fields on another kind are refused too.
        let (consumer, _) = try await rig()
        _ = try await consumer.consume(dismissalStart())
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(event("transcript", sequence: 2, extra: ["turn": turn(),
                                                                               "scope": ["playback"]]))
        }
    }

    @Test func enrolledDecisionDismissalWithRoleEngagementAndCooldownIsAdmitted() async throws {
        let (consumer, _) = try await rig()
        _ = try await consumer.consume(dismissalStart(speakers: "enrolled"))
        let event = try await dismiss(consumer, sequence: 2, role: "participant", changes: [
            "scope": ["playback", "pending_request", "engagement"], "reason": "decision", "confidence": 0.97,
            "cooldown_until_ms": 33_600
        ])
        #expect(try await !consumer.consume(event))
        #expect(await consumer.lastDismissal?.scope == ["playback", "pending_request", "engagement"])
        let (refused, _) = try await rig()
        _ = try await refused.consume(dismissalStart(speakers: "enrolled"))
        let boss = try await dismiss(refused, sequence: 2, changes: ["role": "boss"])
        await #expect(throws: RightyoInputError.invalidEvent) { try await refused.consume(boss) }
    }

    /// Admits a dismissal withdrawing the never-seen `later`, then `later`'s transcript and attention; returns
    /// a builder for `later`'s request at a given sequence, unconsumed.
    func withdrawnLater(_ consumer: RightyoInputConsumer) async throws -> (Int) throws -> RightyoInputEvent {
        _ = try await consumer.consume(dismissalStart())
        let dismissal = try await dismiss(consumer, sequence: 2,
                                          changes: ["withdrawn_request_ids": ["\(session):later"]])
        #expect(try await !consumer.consume(dismissal))
        #expect(await consumer.lastDismissal?.withdrawn == 1)
        let final = turn("later", start: 3700, end: 4000)
        let decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1"]
        _ = try await consumer.consume(event("transcript", sequence: 4, extra: ["turn": final, "emitted_at_ms": 4000]))
        _ = try await consumer.consume(event("attention", sequence: 5, extra: [
            "utterance_id": "later", "request_id": "\(session):later", "decision": decision, "emitted_at_ms": 4000
        ]))
        return { sequence in
            try self.event("request", sequence: sequence, extra: [
                "request_id": "\(self.session):later", "turn": final, "decision": decision, "context": ["turns": []],
                "decision_at_ms": 4000, "emitted_at_ms": 4000
            ])
        }
    }

    @Test func aWithdrawnRequestThatArrivesLaterIsDroppedAndTheSessionGoesOn() async throws {
        let (consumer, adapter) = try await rig()
        let late = try await withdrawnLater(consumer)
        #expect(try await !consumer.consume(late(6)))
        #expect(await consumer.withdrawnDropped == 1)
        _ = try await consumer.consume(stopped(7))
        try await consumer.finish()
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func aDeliveredRequestIsLeftAloneAndCountedAsAlreadyDelivered() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(dismissalStart())
        #expect(try await consumer.consume(preparedRequest(consumer)))
        let event = try await dismiss(consumer, sequence: 5, changes: [
            "withdrawn_request_ids": ["\(session):request", "\(session):never-seen"]
        ])
        #expect(try await !consumer.consume(event))
        #expect(await consumer.lastDismissal == RightyoDismissReceipt(
            reason: "stop-phrase", scope: ["playback", "pending_request"], withdrawn: 1, alreadyDelivered: 1))
        _ = try await consumer.consume(stopped(7))
        try await consumer.finish()
        #expect(await adapter.deliveries.count == 1)
    }

    /// RightyO's authored `examples/dismissal-events.jsonl` (rightyo PR #99), byte-identical.
    @Test func producerDismissalFixtureValidatesDryAndDeliversItsRequestOnce() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/rightyo/dismissal-events.jsonl")
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        let dry = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run", session: "dismissal-demo")
        var requests = 0, dismissals: [RightyoDismissReceipt] = []
        for line in lines {
            requests += try await dry.consume(RightyoInputEvent.decode(Data(line.utf8))) ? 1 : 0
            if let receipt = await dry.lastDismissal { dismissals.append(receipt) }
        }
        try await dry.finish()
        #expect(requests == 1)
        #expect(dismissals == [RightyoDismissReceipt(reason: "stop-phrase", scope: ["playback", "pending_request"],
                                                     withdrawn: 0, alreadyDelivered: 1)])
    }
}
