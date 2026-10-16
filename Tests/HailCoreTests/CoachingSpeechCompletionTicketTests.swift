import Foundation
import Testing
@testable import HailCore

@Suite("Bounded host speech completion permits") @MainActor
struct CoachingSpeechCompletionTicketTests {
    @Test func originalAdmissionDeadlineIsRetainedAndCannotBePromotedLateOrTwice() throws {
        let rig = CoachingTestHarness()
        try rig.begin()
        let original = try rig.ticket()
        let promoted = try original.permittingSpeech(at: rig.time.instant)
        #expect(promoted.qualification == original.qualification && promoted.requestID == original.requestID)
        #expect(promoted.expiresAt == rig.time.instant.advanced(by: .seconds(18)))
        #expect(original.expiresAt == original.qualification.expiresAt)
        #expect(throws: CoachingSafetyError.staleQualification) {
            try original.permittingSpeech(at: original.qualification.expiresAt)
        }
        #expect(throws: CoachingSafetyError.staleQualification) {
            try promoted.permittingSpeech(at: rig.time.instant)
        }
        rig.session.stop()
    }

    @Test func renewedPrivateRouteAllowsLongSpeechButNeverExtendsCompletion() throws {
        let rig = CoachingTestHarness()
        var lease = try rig.begin()
        let ticket = try rig.ticket().permittingSpeech(at: rig.time.instant)
        for _ in 0..<17 {
            rig.time.advance(.seconds(1))
            lease = try rig.session.renew(lease)
            try rig.session.schedule(coachingPCM, ticket: ticket)
            rig.player.completions.last?()
        }
        rig.time.advance(.seconds(1))
        #expect(rig.session.qualification != nil)
        #expect(throws: CoachingSafetyError.staleQualification) {
            try rig.session.schedule(coachingPCM, ticket: ticket)
        }
        rig.session.stop()
    }

    @Test func queuedLongSpeechExpiresEvenIfPrivateLeaseKeepsRenewing() throws {
        let rig = CoachingTestHarness()
        var lease = try rig.begin()
        let ticket = try rig.ticket().permittingSpeech(at: rig.time.instant)
        try rig.session.schedule(coachingPCM, ticket: ticket)
        for _ in 0..<17 {
            rig.time.advance(.seconds(1))
            lease = try rig.session.renew(lease)
        }
        rig.time.advance(.seconds(1))
        #expect(rig.session.qualification == nil && rig.suspensions == [.adviceExpired])
        #expect(rig.capture.stopCount == 1 && rig.player.cancelled == 1)
    }

    @Test func routeLossStopAndCueCancellationStillFencePendingSpeech() throws {
        for loss in 0..<3 {
            let rig = CoachingTestHarness()
            try rig.begin()
            let ticket = try rig.ticket().permittingSpeech(at: rig.time.instant)
            try rig.session.schedule(coachingPCM, ticket: ticket)
            switch loss {
            case 0: rig.output = .unqualified; rig.session.invalidateRoute()
            case 1: rig.session.stop()
            default: rig.session.cancelSpeech()
            }
            #expect(rig.session.pendingPlayback.isEmpty && rig.player.cancelled == 1)
            if loss == 2 {
                #expect(rig.session.qualification != nil && rig.capture.stopCount == 0)
                rig.session.stop()
            } else {
                #expect(rig.session.qualification == nil && rig.capture.stopCount == 1)
                #expect(throws: CoachingSafetyError.staleQualification) { try rig.session.validate(ticket) }
            }
        }
    }
}
