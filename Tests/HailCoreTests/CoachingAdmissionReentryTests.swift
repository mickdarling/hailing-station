import Foundation
import Testing
@testable import HailCore

/// #269: final route observation is callback-capable; it cannot bypass replay or ledger bounds.
@Suite @MainActor struct CoachingAdmissionReentryTests {
    @Test func finalObserverReentryCannotAdmitTheSameRequestTwice() throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        let wire = try coachingWireData(lease)
        var observations = 0
        var inner: AdmittedCoachingAdvice?
        rig.onObserve = {
            observations += 1
            guard observations == 2 else { return }
            rig.onObserve = nil
            inner = try? consumer.admit(wire)
        }
        #expect(throws: CoachingWireError.replay) { try consumer.admit(wire) }
        #expect(observations == 2 && inner != nil)
        #expect(throws: CoachingWireError.replay) { try consumer.admit(wire) }
        consumer.stop()
    }

    @Test func finalObserverReentryCannotExceedTheLastRequestSlot() throws {
        let rig = CoachingTestHarness()
        let consumer = try coachingConsumer(rig)
        let lease = try rig.begin()
        try consumer.register(lease)
        for _ in 1..<CoachingAdviceConsumer.requestLimit {
            _ = try consumer.admit(coachingWireData(lease))
        }
        let nestedWire = try coachingWireData(lease)
        let outerWire = try coachingWireData(lease)
        var observations = 0
        var inner: AdmittedCoachingAdvice?
        rig.onObserve = {
            observations += 1
            guard observations == 2 else { return }
            rig.onObserve = nil
            inner = try? consumer.admit(nestedWire)
        }
        #expect(throws: CoachingWireError.ledgerFull) { try consumer.admit(outerWire) }
        #expect(observations == 2 && inner != nil)
        #expect(rig.session.current() == nil && rig.capture.stopCount == 1)
        #expect(throws: CoachingWireError.staleAdvice) { try consumer.resume(#require(inner)) }
        #expect(rig.player.resumed == 0)
    }
}
