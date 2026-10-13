import Foundation
import Testing
@testable import HailCore

/// #269/#225: expiring route correlation never confers tool or action authority.
@Suite("Private coaching original deadlines")
@MainActor
struct PrivateCoachingLifetimeTests {
    @Test func expiryStopsIdleCaptureWithoutAnotherInput() throws {
        let rig = CoachingTestHarness()
        let lease = try rig.begin()
        rig.time.advance(.seconds(2))
        #expect(rig.session.qualification == nil)
        #expect(rig.capture.stopCount == 1 && rig.player.cancelled == 1)
        #expect(rig.suspensions == [.qualificationExpired])
        #expect(throws: CoachingSafetyError.staleQualification) { try rig.session.renew(lease) }
    }

    @Test func renewalDoesNotExtendOldAdviceAndStaleTimerCannotStopNewLease() throws {
        let rig = CoachingTestHarness()
        let lease = try rig.begin()
        let old = try rig.ticket()
        rig.time.advance(.seconds(1))
        let renewed = try rig.session.renew(lease)
        #expect(renewed.qualificationID != lease.qualificationID && renewed.generation == lease.generation)
        rig.time.advance(.seconds(1))
        #expect(rig.session.qualification == renewed)
        #expect(throws: CoachingSafetyError.staleQualification) {
            try rig.session.schedule(coachingPCM, ticket: old)
        }
        try rig.session.schedule(coachingPCM, ticket: rig.ticket())
        rig.session.stop()
    }

    @Test func renewalCannotExtendAlreadyQueuedAudioDeadline() throws {
        let rig = CoachingTestHarness()
        let lease = try rig.begin()
        try rig.session.schedule(coachingPCM, ticket: rig.ticket())
        rig.time.advance(.seconds(1))
        try rig.session.renew(lease)
        rig.time.advance(.seconds(1))
        #expect(rig.session.qualification == nil)
        #expect(rig.suspensions == [.adviceExpired])
        #expect(rig.player.cancelled == 1)
    }

    @Test func completedChunksReleaseDeadlineButOldRenewalCannotRefresh() throws {
        let rig = CoachingTestHarness()
        let lease = try rig.begin()
        try rig.session.schedule(coachingPCM, ticket: rig.ticket())
        rig.time.advance(.seconds(1))
        let renewed = try rig.session.renew(lease)
        rig.player.completions.forEach { $0() }
        rig.time.advance(.seconds(1))
        #expect(rig.session.qualification == renewed)
        #expect(throws: CoachingSafetyError.staleQualification) { try rig.session.renew(lease) }
        rig.session.stop()
    }

    @Test func boundedLifetimeQueueAndPayloads() throws {
        let rig = CoachingTestHarness()
        for duration in [Duration.zero, .seconds(-1), .seconds(3)] {
            #expect(throws: CoachingSafetyError.invalidLifetime) {
                try rig.session.begin(sessionID: UUID(), destinationID: UUID(),
                                      consentConfirmed: true, lifetime: duration)
            }
        }
        try rig.begin()
        var invalid = coachingPCM
        invalid.bytes = Data([1])
        #expect(throws: CoachingSafetyError.invalidAudio) { try rig.session.schedule(invalid, ticket: rig.ticket()) }
        for _ in 0..<32 { try rig.session.schedule(coachingPCM, ticket: rig.ticket()) }
        #expect(throws: CoachingSafetyError.queueFull) {
            try rig.session.schedule(coachingPCM, ticket: rig.ticket())
        }
        #expect(rig.player.scheduled.count == 32)
        rig.session.stop()
    }

    @Test func playerFailureRetiresWholeLifetime() throws {
        let rig = CoachingTestHarness()
        try rig.begin()
        rig.player.fails = true
        #expect(throws: CoachingSafetyError.invalidAudio) {
            try rig.session.schedule(coachingPCM, ticket: rig.ticket())
        }
        #expect(rig.suspensions == [.playbackFailed])
        #expect(rig.capture.stopCount == 1 && rig.session.qualification == nil)
    }
}
