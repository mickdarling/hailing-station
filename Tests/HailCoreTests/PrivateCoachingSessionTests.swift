import Foundation
import Testing
@testable import HailCore

/// #269/#268: qualified private playback is a separate opt-in, not a global echo-mask bypass.
@Suite("Private coaching admission and route fencing")
@MainActor
struct PrivateCoachingSessionTests {
    @Test func defaultOffAndConsentPrecedesCapture() throws {
        let rig = CoachingTestHarness()
        #expect(rig.session.qualification == nil)
        #expect(rig.capture.startCount == 0)
        #expect(throws: CoachingSafetyError.consentRequired) {
            try rig.session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: false)
        }
        rig.output = .unqualified
        #expect(throws: CoachingSafetyError.unsafeOutput) { try rig.begin() }
        #expect(rig.capture.startCount == 0)
    }

    @Test func rawCaptureContinuesDuringPrivatePlayback() async throws {
        let rig = CoachingTestHarness()
        try rig.begin()
        try rig.session.schedule(coachingPCM, ticket: rig.ticket())
        try rig.capture.yield(sineBuffer())
        await drainCoachingTasks()
        #expect(rig.admitted.count == 1)
        let samples = try #require(rig.admitted.first?.pcmBuffer.floatChannelData?[0])
        #expect(abs(samples[12]) > 0.49)
        #expect(rig.player.scheduled == [coachingPCM])
        #expect(rig.capture.stopCount == 0)
        rig.session.stop()
    }

    @Test func observedUnknownOrDifferentOutputVetoesChunkResumeAndUnmute() throws {
        for observation in [CoachingOutputObservation.unqualified, .verifiedHeadphones(UUID())] {
            for action in 0..<3 {
                let rig = CoachingTestHarness()
                try rig.begin()
                let ticket = try rig.ticket()
                rig.output = observation
                #expect(throws: CoachingSafetyError.staleQualification) {
                    switch action {
                    case 0: try rig.session.schedule(coachingPCM, ticket: ticket)
                    case 1: try rig.session.resume(ticket: ticket)
                    default: try rig.session.setMuted(false, ticket: ticket)
                    }
                }
                #expect(rig.session.qualification == nil)
                #expect(rig.capture.stopCount == 1)
                #expect(rig.player.scheduled.isEmpty && rig.player.resumed == 0 && rig.player.mutes.isEmpty)
            }
        }
    }

    @Test func notificationCancelsQueuedAndLateAdviceEvenIfRouteReturns() async throws {
        let rig = CoachingTestHarness()
        let lease = try rig.begin()
        let ticket = try rig.ticket()
        try rig.session.schedule(coachingPCM, ticket: ticket)
        try rig.capture.yield(sineBuffer())
        rig.session.invalidateRoute()
        await drainCoachingTasks()
        #expect(rig.admitted.isEmpty)
        #expect(rig.player.cancelled == 1)
        #expect(rig.suspensions == [.routeInvalidated])
        let fresh = try rig.begin()
        #expect(fresh.generation != lease.generation)
        #expect(throws: CoachingSafetyError.staleQualification) {
            try rig.session.schedule(coachingPCM, ticket: ticket)
        }
        rig.player.completions.forEach { $0() } // Retired completions cannot change the new timer.
        #expect(rig.session.qualification == fresh)
        rig.session.stop()
    }

    @Test func captureObservationVetoesForwarding() async throws {
        let rig = CoachingTestHarness()
        try rig.begin()
        rig.output = .unqualified
        try rig.capture.yield(sineBuffer())
        await drainCoachingTasks()
        #expect(rig.admitted.isEmpty)
        #expect(rig.suspensions == [.routeInvalidated])
    }

    @Test func stopIsIdempotentAndReentrantBeginIsRejected() throws {
        let rig = CoachingTestHarness()
        try rig.begin()
        rig.player.onCancel = {
            #expect(throws: CoachingSafetyError.transitionInProgress) { try rig.begin() }
        }
        rig.session.stop()
        rig.session.stop()
        #expect(rig.player.cancelled == 1 && rig.capture.stopCount == 1)
        #expect(rig.session.qualification == nil)
        rig.player.onCancel = nil
    }
}
