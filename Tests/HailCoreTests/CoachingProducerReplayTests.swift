import Foundation
import Testing
@testable import HailCore

/// Optional cross-repository probe: unmodified bytes from actual synthetic RightyO executable output.
/// This test-only host ledger installs the authored IDs. Production cannot import or mint wire qualifications.
@Suite @MainActor struct CoachingProducerReplayTests {
    nonisolated static let replayPath = ProcessInfo.processInfo.environment["HAIL_COACHING_REPLAY_JSONL"]

    private struct Replay {
        let wire: CoachingWireAdvice
        let data: Data
        let lines: [Data]
    }

    @Test(.enabled(if: replayPath != nil))
    func actualProducerBytesAdmitOnceOnlyThroughPrivateSyntheticHostLedger() throws {
        let replay = try replayAdvice()
        let wire = replay.wire
        let data = replay.data
        let rig = CoachingTestHarness()
        let consumer = try CoachingAdviceConsumer(session: rig.session, listenerID: wire.listenerID)
        let lease = try installAuthoredQualification(wire, in: rig)
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.admit(data) }
        try consumer.register(lease)
        let advice = try consumer.admit(data)
        #expect(advice.text == wire.text && advice.ticket.requestID.uuidString.lowercased() == wire.requestID)
        #expect(advice.ticket.qualification.expiresAt <= lease.expiresAt)
        try consumer.schedule(coachingPCM, for: advice)
        #expect(rig.player.scheduled == [coachingPCM])
        #expect(throws: CoachingWireError.replay) { try consumer.admit(data) }
        for line in replay.lines where line != data {
            #expect(throws: CoachingWireError.invalidMessage) { try consumer.admit(line) }
        }
        consumer.invalidate()
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.resume(advice) }
        #expect(rig.capture.stopCount == 1 && rig.player.cancelled == 1)
    }

    @Test(.enabled(if: replayPath != nil))
    func actualProducerBytesCannotCrossDestinationOrOriginalExpiry() throws {
        let replay = try replayAdvice()
        let wire = replay.wire
        let data = replay.data
        let rig = CoachingTestHarness()
        let consumer = try CoachingAdviceConsumer(session: rig.session, listenerID: wire.listenerID)
        var lease = try installAuthoredQualification(wire, in: rig)
        try consumer.register(lease)
        let advice = try consumer.admit(data)
        var wrong = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        wrong["destination_id"] = UUID().uuidString.lowercased()
        #expect(throws: CoachingWireError.wrongScope) { try consumer.admit(coachingWireData(wrong)) }
        rig.time.advance(.seconds(1))
        lease = try rig.session.renew(lease)
        try consumer.register(lease)
        rig.time.advance(.seconds(1))
        #expect(rig.session.current() == lease)
        #expect(throws: CoachingWireError.unknownQualification) { try consumer.admit(data) }
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.schedule(coachingPCM, for: advice) }
        #expect(rig.player.scheduled.isEmpty)
        consumer.stop()
    }

    private func replayAdvice() throws -> Replay {
        let path = try #require(Self.replayPath)
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let lines = source.split(separator: "\n").map { Data($0.utf8) }
        let advice = lines.compactMap { data -> (CoachingWireAdvice, Data)? in
            guard let wire = try? CoachingWireAdvice.decode(data) else { return nil }
            return (wire, data)
        }
        #expect(advice.count == 1 && lines.count == 6)
        let item = try #require(advice.first)
        return Replay(wire: item.0, data: item.1, lines: lines)
    }

    private func installAuthoredQualification(_ wire: CoachingWireAdvice, in rig: CoachingTestHarness) throws
        -> CoachingQualification {
        let started = try rig.session.begin(
            sessionID: #require(UUID(uuidString: wire.sessionID)),
            destinationID: #require(UUID(uuidString: wire.destinationID)), consentConfirmed: true
        )
        let lease = try CoachingQualification(
            sessionID: started.sessionID, generation: #require(UUID(uuidString: wire.generationID)),
            destinationID: started.destinationID, qualificationID: #require(UUID(uuidString: wire.qualificationID)),
            expiresAt: started.expiresAt, outputID: started.outputID
        )
        rig.session.qualification = lease // Test-only fixed IDs for the producer's authored controls.
        rig.session.armExpiry(lease)
        return lease
    }
}
