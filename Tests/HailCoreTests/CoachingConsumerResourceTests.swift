import Foundation
import Testing
@testable import HailCore

/// #269: bounded correlation fails closed instead of evicting replay protection or reviving old work.
@Suite @MainActor struct CoachingConsumerResourceTests {
    /// Yields between admissions so filling the ledger never holds the main actor in one block (#704).
    @Test func requestLedgerExhaustionStopsOwnedLifetime() async throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        var first: AdmittedCoachingAdvice?
        for _ in 0..<CoachingAdviceConsumer.requestLimit {
            let advice = try consumer.admit(coachingWireData(lease))
            if first == nil { first = advice }
            await Task.yield()
        }
        #expect(throws: CoachingWireError.ledgerFull) { try consumer.admit(coachingWireData(lease)) }
        #expect(rig.session.current() == nil && rig.capture.stopCount == 1)
        #expect(throws: CoachingWireError.staleAdvice) {
            try consumer.resume(#require(first))
        }
        #expect(rig.player.resumed == 0 && rig.player.scheduled.isEmpty)
    }

    @Test func qualificationLedgerIsBoundedAndDuplicateRegistrationDoesNotConsumeCapacity() throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        var lease = try rig.begin()
        try consumer.register(lease)
        for _ in 1..<CoachingAdviceConsumer.qualificationLimit {
            try consumer.register(lease)
            lease = try rig.session.renew(lease)
            try consumer.register(lease)
        }
        try consumer.register(lease)
        lease = try rig.session.renew(lease)
        #expect(throws: CoachingWireError.ledgerFull) { try consumer.register(lease) }
        #expect(rig.session.current() == nil && rig.capture.stopCount == 1)
    }

    @Test func currentRouteVetoAppliesToResumeUnmuteAndDelayedPCM() throws {
        for operation in 0..<3 {
            let rig = CoachingTestHarness()
            let consumer = try coachingConsumer(rig)
            let lease = try rig.begin()
            try consumer.register(lease)
            let advice = try consumer.admit(coachingWireData(lease))
            rig.output = .unqualified
            #expect(throws: CoachingWireError.staleAdvice) {
                switch operation {
                case 0: try consumer.resume(advice)
                case 1: try consumer.setMuted(false, for: advice)
                default: try consumer.schedule(coachingPCM, for: advice)
                }
            }
            #expect(rig.player.resumed == 0 && rig.player.mutes.isEmpty && rig.player.scheduled.isEmpty)
            #expect(rig.capture.stopCount == 1)
        }
    }
}
