import Foundation
import Testing
@testable import HailCore

/// #269 / PR #557: stale wrapper cleanup must not revoke a newer lease in the same generation.
@Suite @MainActor struct AppleCoachingRenewalOwnershipTests {
    @Test(arguments: [false, true])
    func failedOldRenewalPreservesNewerLeaseAndCapture(reenterObservation: Bool) throws {
        let rig = AppleCoachingRig()
        let adapter = try rig.make()
        let old = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        var renewed: CoachingQualification?
        if reenterObservation {
            rig.onSnapshot = {
                rig.onSnapshot = nil
                do { renewed = try adapter.renew(old) } catch { Issue.record(error) }
            }
        } else {
            renewed = try adapter.renew(old)
        }
        #expect(throws: (any Error).self) { try adapter.renew(old) }
        let fresh = try #require(renewed)
        #expect(fresh.generation == old.generation && fresh != old)
        #expect(rig.capture.startCount == 1 && rig.capture.stopCount == 0 && rig.suspensions.isEmpty)
        let advice = try adapter.admit(coachingWireData(fresh))
        try adapter.schedule(coachingPCM, for: advice)
        #expect(rig.frameCounts == [2] && rig.plays == 1)
        adapter.stop()
        #expect(rig.capture.stopCount == 1 && rig.suspensions == [.stopped])
    }
}
