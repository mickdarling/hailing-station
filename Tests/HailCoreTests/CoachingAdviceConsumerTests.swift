import Foundation
import Testing
@testable import HailCore

/// #269: authored wire suggestions reach only qualified private synthetic playback after full host admission.
@Suite @MainActor struct CoachingAdviceConsumerTests {
    @Test func originalQualificationAndProducerIssuedRequestAdmitOnce() async throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        let wire = try coachingWireData(lease)
        // No registered generation exists yet, so no incoming wire can be live.
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.admit(wire) }
        try consumer.register(lease)
        let advice = try consumer.admit(wire)
        try consumer.schedule(coachingPCM, for: advice)
        try rig.capture.yield(sineBuffer())
        await drainCoachingTasks()
        #expect(rig.admitted.count == 1 && rig.player.scheduled == [coachingPCM])
        #expect(throws: CoachingWireError.replay) { try consumer.admit(wire) }
        consumer.stop()
    }

    @Test func wrongScopeAndUnknownQualificationCannotBecomeTickets() throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        for key in ["session_id", "generation_id", "destination_id", "listener_id", "qualification_id"] {
            var object = try #require(JSONSerialization.jsonObject(with: coachingWireData(lease)) as? [String: Any])
            object[key] = key == "listener_id" ? "another-coach" : UUID().uuidString.lowercased()
            let expected: CoachingWireError = key == "qualification_id" ? .unknownQualification : .wrongScope
            #expect(throws: expected) { try consumer.admit(coachingWireData(object)) }
        }
        #expect(rig.player.scheduled.isEmpty)
        consumer.stop()
    }

    @Test func senderTTLCanShortenButNeverExtendHostOriginalDeadline() throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        let short = try consumer.admit(coachingWireData(lease, ttl: 100))
        #expect(short.ticket.qualification.expiresAt == rig.time.instant.advanced(by: .milliseconds(100)))
        rig.time.advance(.milliseconds(1_900))
        let long = try consumer.admit(coachingWireData(lease, ttl: 2_000))
        #expect(long.ticket.qualification.expiresAt == lease.expiresAt)
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.schedule(coachingPCM, for: short) }
        consumer.stop()
    }

    @Test func renewalAndExpiredReceiptNeverMakeARequestReplayable() throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        let requestID = UUID()
        _ = try consumer.admit(coachingWireData(lease, requestID: requestID, ttl: 100))
        rig.time.advance(.seconds(1))
        let renewed = try rig.session.renew(lease)
        try consumer.register(renewed)
        #expect(throws: CoachingWireError.replay) {
            try consumer.admit(coachingWireData(renewed, requestID: requestID))
        }
        rig.time.advance(.seconds(1))
        #expect(throws: CoachingWireError.unknownQualification) { try consumer.admit(coachingWireData(lease)) }
        consumer.stop()
    }

    @Test func invalidationFencesDelayedRendererAndControlsCannotBeAdvice() throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        let delayed = try consumer.admit(coachingWireData(lease))
        consumer.invalidate()
        let fresh = try rig.begin()
        try consumer.register(fresh)
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.schedule(coachingPCM, for: delayed) }
        #expect(throws: CoachingWireError.invalidMessage) { try consumer.admit(coachingWireFixture()[0]) }
        #expect(rig.player.scheduled.isEmpty)
        consumer.stop()
    }

    @Test func adviceCannotBeMovedToAnotherConsumer() throws {
        let rig = CoachingTestHarness()
        let first = try coachingConsumer(rig)
        let second = try coachingConsumer(rig)
        let lease = try rig.begin()
        try first.register(lease)
        try second.register(lease)
        let wire = try coachingWireData(lease)
        let advice = try first.admit(wire)
        _ = try second.admit(wire)
        #expect(throws: CoachingWireError.staleAdvice) { try second.schedule(coachingPCM, for: advice) }
        first.stop()
    }
}
