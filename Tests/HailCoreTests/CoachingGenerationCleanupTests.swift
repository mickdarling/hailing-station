import Foundation
import Testing
@testable import HailCore

/// #269: an old operation has no cleanup authority over a replacement generation.
@Suite @MainActor struct CoachingGenerationCleanupTests {
    @Test func replacementDuringOutputObservationSurvivesOldRouteMismatch() throws {
        let rig = CoachingTestHarness()
        let old = try rig.begin()
        var fresh: CoachingQualification?
        rig.onObserve = {
            rig.onObserve = nil
            rig.output = .verifiedHeadphones(UUID())
            do { fresh = try rig.begin() } catch { Issue.record(error) }
        }
        #expect(rig.session.current() == nil)
        let lease = try #require(fresh)
        #expect(lease.generation != old.generation && rig.session.current() == lease)
        #expect(rig.capture.startCount == 2 && rig.capture.stopCount == 1 && rig.suspensions == [.stopped])
        try rig.session.schedule(coachingPCM, ticket: rig.ticket())
        rig.session.stop()
    }

    @Test func replacementDuringClockReadSurvivesOldDeadlineFailure() throws {
        let rig = CoachingTestHarness()
        let old = try rig.begin()
        rig.time.instant = old.expiresAt.advanced(by: .seconds(1))
        var fresh: CoachingQualification?
        rig.time.onNow = {
            rig.time.onNow = nil
            do { fresh = try rig.begin() } catch { Issue.record(error) }
        }
        #expect(rig.session.current() == nil)
        #expect(rig.session.current() == fresh && fresh != nil && rig.capture.stopCount == 1)
        rig.session.stop()
    }

    @Test func oldRendererThrowCannotRetireReplacementWithQueuedAdvice() throws {
        for scheduling in [false, true] {
            let rig = CoachingTestHarness()
            _ = try rig.begin()
            let ticket = try rig.ticket()
            var fresh: CoachingQualification?
            rig.player.onEffect = {
                rig.player.onEffect = nil
                fresh = try rig.begin()
                try rig.session.schedule(coachingPCM, ticket: rig.ticket())
                throw CoachingSafetyError.invalidAudio
            }
            #expect(throws: CoachingSafetyError.invalidAudio) {
                if scheduling { try rig.session.schedule(coachingPCM, ticket: ticket) } else {
                    try rig.session.resume(ticket: ticket)
                }
            }
            #expect(rig.session.current() == fresh && fresh != nil && rig.capture.stopCount == 1)
            #expect(rig.suspensions == [.stopped] && rig.player.scheduled.count == 1)
            try rig.session.resume(ticket: rig.ticket())
            rig.session.stop()
        }
    }
}
