import Foundation
import Testing
@testable import HailDaemonKit

/// Shared authored v1 controls, exact-child/request acks and revocation; no speech or provider.
@Suite(.frozenGuardBudget) struct RightyoRequestOutcomeTests {
    let fixture = RightyoInputConsumerTests()
    func started(version: Any = 1) throws -> RightyoInputEvent {
        try fixture.event("session", sequence: 1, extra: ["phase": "started", "capabilities": [
            "activation": "finalized-turn", "partials": false, "speakers": "anonymous", "context": true
        ], "request_outcomes": ["version": version]])
    }
    func ack(_ state: String = "accepted", producer: String = "tool-demo:request", version: Int = 1,
             sequence: Int = 5) throws -> RightyoInputEvent {
        try fixture.event("request_outcome", sequence: sequence,
                          extra: ["request_id": producer, "state": state, "version": version])
    }
    @Test func anAtomicWriteIsNotAnAcknowledgement() throws {
        let ledger = AmbientRequestOutcomes(session: fixture.session), host = UUID()
        #expect(!ledger.register(host: host, producer: "tool-demo:request"))
        ledger.observe(try started())
        #expect(ledger.register(host: host, producer: "tool-demo:request"))
        #expect(ledger.report(.accepted, host: host, write: { $0.line != nil }))
        #expect(!ledger.isConfirmed(host, .accepted))
        ledger.observe(try ack(producer: "tool-demo:foreign", sequence: 2))
        ledger.observe(try ack("failed", sequence: 3))
        #expect(!ledger.isConfirmed(host, .accepted))
        ledger.observe(try ack(version: 2, sequence: 4))
        #expect(!ledger.isConfirmed(host, .accepted))
        ledger.observe(try ack())
        #expect(ledger.isConfirmed(host, .accepted))
        #expect(ledger.report(.replyStarted, host: host, write: { _ in true }))
        ledger.observe(try ack()) // An old ack never confirms the new transaction.
        #expect(!ledger.isConfirmed(host, .replyStarted))
        ledger.observe(try ack("reply_started", sequence: 6))
        #expect(ledger.isConfirmed(host, .replyStarted))
    }
    @Test func aDroppedWriteMayRetryAndRetirementRevokesAuthority() throws {
        let ledger = AmbientRequestOutcomes(session: fixture.session), host = UUID()
        ledger.observe(try started())
        #expect(ledger.register(host: host, producer: "tool-demo:request"))
        #expect(!ledger.report(.accepted, host: host, write: { _ in false }))
        #expect(ledger.report(.accepted, host: host, write: { _ in true }))
        ledger.observe(try ack())
        ledger.revokeRequests()
        #expect(!ledger.contains(host))
        ledger.observe(try ack())
        #expect(!ledger.isConfirmed(host, .accepted))
        #expect(!ledger.report(.timedOut, host: host, write: { _ in true }))
        ledger.close()
        ledger.observe(try started())
        #expect(!ledger.supported)
    }
    @Test func futureOrMalformedCapabilitiesStayUnsupported() throws {
        for version: Any in [0, 2, true, "1"] {
            let ledger = AmbientRequestOutcomes(session: fixture.session)
            ledger.observe(try started(version: version))
            #expect(!ledger.supported)
        }
    }
    @Test func consumerRequiresCapabilityAndAnAlreadyAdmittedRequest() async throws {
        let consumer = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original",
                                                session: fixture.session, allowSynthetic: true)
        _ = try await consumer.consume(started())
        let request = try await fixture.preparedRequest(consumer)
        #expect(try await consumer.consume(request))
        #expect(try await !consumer.consume(ack()))
        let unadvertised = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original",
                                                    session: fixture.session, allowSynthetic: true)
        _ = try await unadvertised.consume(fixture.start())
        let other = try await fixture.preparedRequest(unadvertised)
        _ = try await unadvertised.consume(other)
        await #expect(throws: RightyoInputError.invalidEvent) { try await unadvertised.consume(ack()) }
    }
    @Test func malformedAcksAndControlsRefuse() throws {
        #expect(throws: RightyoInputError.invalidEvent) {
            try ack(version: 2).validate(session: fixture.session, enrolled: false)
        }
        #expect(throws: RightyoInputError.invalidEvent) {
            try ack(producer: "foreign:request").validate(session: fixture.session, enrolled: false)
        }
        let bad = RightyoRequestOutcome(session: fixture.session, request: "foreign:request", state: .accepted)
        #expect(bad.line == nil)
        let asked = RightyoRequestOutcome(session: fixture.session, request: "tool-demo:request",
                                          state: .accepted, asked: true)
        #expect(asked.line == nil)
    }
    @Test func sharedContractFixtureMatchesRightyoProducer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/testing/request-outcomes-v1.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accepted = try #require(object["accepted"] as? [String: Any])
        let control = RightyoRequestOutcome(session: "authored-session", request: "authored-session:turn-1",
                                            state: .accepted)
        let line = try #require(control.line)
        let encoded = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
        #expect(encoded.isEqual(to: accepted))
        #expect(Set(object["states"] as? [String] ?? []) == Set(RightyoRequestOutcomeState.allCases.map(\.rawValue)))
        #expect(line.utf8.count <= 513)
    }
    #if os(macOS)
    @Test func outcomeUsesTheExistingNonblockingChildDescriptor() async throws {
        let fake = try FakeRightyo("/bin/cat <&3 > control.txt")
        defer { fake.cleanUp() }
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config,
                                            session: fixture.session, replyControl: true)
        let value = RightyoRequestOutcome(session: fixture.session, request: "tool-demo:request", state: .timedOut)
        #expect(child.reportRequestOutcome(value))
        #expect(await child.stop() == .exited(0))
        #expect(try fake.recorded("control.txt") == value.line)
        #expect(!child.reportRequestOutcome(value))
    }
    #endif
}

// Test convenience captures the token synchronously; production must retain it across dispatch suspension.
extension AmbientRequestOutcomes {
    func register(host: UUID, producer: String) -> Bool {
        guard let generation else { return false }
        return register(host: host, producer: producer, generation: generation)
    }
}

extension RightyoRequestOutcomeTests {
    @Test func suspendedDeliveryCannotPublishAfterPrivacyOnOffOrClose() throws {
        let ledger = AmbientRequestOutcomes(session: fixture.session)
        ledger.observe(try started())
        let before = try #require(ledger.generation)
        ledger.setPrivate(true)
        #expect(ledger.generation == nil)
        ledger.setPrivate(false)
        #expect(!ledger.register(host: UUID(), producer: "tool-demo:request", generation: before))
        let current = try #require(ledger.generation)
        ledger.close()
        #expect(!ledger.register(host: UUID(), producer: "tool-demo:request", generation: current))
    }
    @Test func terminalPrivacyAndExactProducerRetirementFenceTheLedger() throws {
        let ledger = AmbientRequestOutcomes(session: fixture.session), first = UUID(), second = UUID()
        ledger.observe(try started())
        #expect(ledger.register(host: first, producer: "tool-demo:request"))
        #expect(ledger.register(host: second, producer: "tool-demo:second"))
        ledger.observe(try fixture.event("override", sequence: 6,
            extra: ["superseded_request_id": "tool-demo:request", "by_utterance_id": "owner", "role": "owner"]))
        #expect(!ledger.contains(first))
        #expect(ledger.contains(second))
        ledger.setPrivate(true)
        ledger.observe(try fixture.event("privacy", sequence: 7, extra: ["action": "on", "at_ms": 2000]))
        #expect(!ledger.contains(second))
        #expect(ledger.generation == nil)
        ledger.setPrivate(false)
        #expect(ledger.register(host: second, producer: "tool-demo:second"))
        ledger.observe(try fixture.event("session", sequence: 8, extra: ["phase": "stopped"]))
        #expect(!ledger.supported)
        #expect(!ledger.contains(second))
    }
    @Test func delayedPrivacyAckCannotRestoreAnAlreadyEndedPrivacyWish() throws {
        let ledger = AmbientRequestOutcomes(session: fixture.session)
        ledger.observe(try started())
        ledger.setPrivate(true)
        ledger.setPrivate(false)
        let before = try #require(ledger.generation)
        ledger.observe(try fixture.event("privacy", sequence: 7, extra: ["action": "on", "at_ms": 2000]))
        let after = try #require(ledger.generation)
        #expect(after != before)
        #expect(ledger.register(host: UUID(), producer: "tool-demo:public", generation: after))
    }
    @Test func oldPrivacyReplayCannotRevokeANewerPublicRequest() throws {
        let ledger = AmbientRequestOutcomes(session: fixture.session)
        ledger.observe(try started())
        ledger.setPrivate(true)
        let old = try fixture.event("privacy", sequence: 7, extra: ["action": "on", "at_ms": 2000])
        ledger.observe(old)
        ledger.setPrivate(false)
        let host = UUID()
        #expect(ledger.register(host: host, producer: "tool-demo:public"))
        ledger.observe(old)
        #expect(ledger.contains(host))
    }
}
