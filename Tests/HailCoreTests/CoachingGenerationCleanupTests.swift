import Foundation
import Testing
@testable import HailCore

/// #269: an old operation has no cleanup authority over a replacement generation.
@Suite @MainActor struct CoachingGenerationCleanupTests {
    @Test(arguments: 0..<3, [false, true])
    func finalClockReadCannotControlOrOverwriteReplacement(action: Int, sameGeneration: Bool) throws {
        let rig = CoachingTestHarness()
        let old = try rig.begin()
        let ticket = try rig.ticket()
        var reads = 0
        var fresh: CoachingQualification?
        rig.time.onNow = {
            reads += 1
            guard reads == 3 else { return }
            rig.time.onNow = nil
            do { fresh = try sameGeneration ? rig.session.renew(old) : rig.begin() } catch { Issue.record(error) }
        }
        #expect(throws: CoachingSafetyError.staleQualification) {
            switch action {
            case 0: try rig.session.resume(ticket: ticket)
            case 1: try rig.session.setMuted(false, ticket: ticket)
            default: _ = try rig.session.renew(old)
            }
        }
        #expect(fresh != nil && rig.session.current() == fresh)
        #expect(rig.player.resumed == 0 && rig.player.mutes.isEmpty)
        rig.session.stop()
    }

    @Test func registrationCannotPublishOldLeaseAfterPruneReplacesGeneration() throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let old = try rig.begin()
        var reads = 0
        var fresh: CoachingQualification?
        rig.time.onNow = {
            reads += 1
            guard reads == 3 else { return }
            rig.time.onNow = nil
            do {
                let lease = try rig.begin()
                try consumer.register(lease)
                fresh = lease
            } catch { Issue.record(error) }
        }
        #expect(throws: CoachingWireError.unknownQualification) { try consumer.register(old) }
        let lease = try #require(fresh)
        #expect(rig.session.current() == lease)
        _ = try consumer.admit(coachingWireData(lease))
        consumer.stop()
    }

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
