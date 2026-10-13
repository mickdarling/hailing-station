import Foundation
import Testing
@testable import HailCore

/// #269: old work cannot stop or cancel a replacement created inside its output observation.
@Suite @MainActor struct AppleCoachingReplacementTests {
    @Test func failedOldRenewalCannotStopReplacementFromObservation() throws {
        let rig = AppleCoachingRig()
        let adapter = try rig.make()
        let old = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        var freshAdvice: AdmittedCoachingAdvice?
        rig.onSnapshot = {
            rig.onSnapshot = nil
            do {
                let fresh = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
                let advice = try adapter.admit(coachingWireData(fresh))
                try adapter.schedule(coachingPCM, for: advice)
                freshAdvice = advice
            } catch { Issue.record(error) }
        }
        #expect(throws: (any Error).self) { try adapter.renew(old) }
        #expect(rig.capture.startCount == 2 && rig.capture.stopCount == 1 && rig.suspensions == [.stopped])
        try adapter.resume(try #require(freshAdvice))
        #expect(rig.plays == 2)
        adapter.stop()
    }

    @Test func replacementDuringCoreRendererAndGateObservationPreservesFreshAdvice() throws {
        for action in 0..<3 {
            for boundary in 0..<3 {
                let rig = AppleCoachingRig()
                let adapter = try rig.make()
                let old = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
                let oldAdvice = try adapter.admit(coachingWireData(old))
                var freshAdvice: AdmittedCoachingAdvice?
                var cancellationsAfterReplacement = 0
                var observations = 0
                let rendererSnapshot = action == 0 ? 5 : 4
                let trigger = boundary == 0 ? 1 : rendererSnapshot + boundary - 1
                rig.onSnapshot = {
                    observations += 1
                    guard observations == trigger else { return }
                    rig.onSnapshot = nil
                    do {
                        let fresh = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
                        let advice = try adapter.admit(coachingWireData(fresh))
                        try adapter.schedule(coachingPCM, for: advice)
                        freshAdvice = advice
                        cancellationsAfterReplacement = rig.cancellations
                    } catch { Issue.record(error) }
                }
                #expect(throws: (any Error).self) {
                    switch action {
                    case 0: try adapter.schedule(coachingPCM, for: oldAdvice)
                    case 1: try adapter.resume(oldAdvice)
                    default: try adapter.setMuted(false, for: oldAdvice)
                    }
                }
                #expect(rig.capture.startCount == 2 && rig.capture.stopCount == 1 && rig.suspensions == [.stopped])
                #expect(rig.cancellations == cancellationsAfterReplacement && rig.frameCounts == [2])
                try adapter.resume(try #require(freshAdvice))
                #expect(rig.plays == 2)
                adapter.stop()
            }
        }
    }
}
