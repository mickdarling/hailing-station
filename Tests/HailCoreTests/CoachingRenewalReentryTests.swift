import Foundation
import Testing
@testable import HailCore

/// #269: a transient changed qualification snapshot is not retirement of its live replay ledger.
@Suite @MainActor struct CoachingRenewalReentryTests {
    @Test func observerRenewalDuringAdmissionPreservesGenerationReplayProtection() throws {
        try checkRenewal(duringConsumption: false)
    }

    @Test func observerRenewalDuringConsumptionPreservesGenerationReplayProtection() throws {
        try checkRenewal(duringConsumption: true)
    }

    private func checkRenewal(duringConsumption: Bool) throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        let requestID = UUID()
        let advice = try consumer.admit(coachingWireData(lease, requestID: requestID))
        var renewed: CoachingQualification?
        rig.onObserve = {
            rig.onObserve = nil
            do {
                let fresh = try rig.session.renew(lease)
                try consumer.register(fresh)
                renewed = fresh
            } catch { Issue.record(error) }
        }
        #expect(throws: CoachingWireError.staleAdvice) {
            if duringConsumption { try consumer.resume(advice) } else {
                _ = try consumer.admit(coachingWireData(lease))
            }
        }
        let fresh = try #require(renewed)
        #expect(fresh.generation == lease.generation && rig.session.current() == fresh)
        try consumer.register(fresh)
        #expect(throws: CoachingWireError.replay) {
            try consumer.admit(coachingWireData(fresh, requestID: requestID))
        }
        #expect(rig.player.resumed == 0)
        consumer.stop()
    }

    @Test func observerReplacementCannotEraseNewGenerationsAlreadyRegisteredRequests() throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let old = try rig.begin()
        try consumer.register(old)
        let requestID = UUID()
        var fresh: CoachingQualification?
        rig.onObserve = {
            rig.onObserve = nil
            do {
                let lease = try rig.begin()
                try consumer.register(lease)
                _ = try consumer.admit(coachingWireData(lease, requestID: requestID))
                fresh = lease
            } catch { Issue.record(error) }
        }
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.admit(coachingWireData(old)) }
        let lease = try #require(fresh)
        #expect(lease.generation != old.generation && rig.session.current() == lease)
        try consumer.register(lease)
        #expect(throws: CoachingWireError.replay) {
            try consumer.admit(coachingWireData(lease, requestID: requestID))
        }
        consumer.stop()
    }
}
