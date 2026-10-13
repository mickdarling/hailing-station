import Foundation
import Testing
@testable import HailCore

/// #269: renderer observation cannot turn pre-call authorization into an expired output effect.
@Suite @MainActor struct AppleCoachingEffectDeadlineTests {
    @Test func expiryInsideRendererObservationVetoesScheduleResumeAndUnmute() throws {
        for action in 0..<3 {
            let rig = AppleCoachingRig()
            let adapter = try rig.make()
            let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
            let advice = try adapter.admit(coachingWireData(lease))
            var observations = 0
            rig.onSnapshot = {
                observations += 1
                // Core final validation precedes renderer: schedule has four snapshots, controls three.
                if observations == (action == 0 ? 5 : 4) {
                    rig.time.instant = rig.time.instant.advanced(by: .seconds(3)) // Deliberately no timer delivery.
                }
            }
            #expect(throws: (any Error).self) {
                switch action {
                case 0: try adapter.schedule(coachingPCM, for: advice)
                case 1: try adapter.resume(advice)
                default: try adapter.setMuted(false, for: advice)
                }
            }
            #expect(rig.frameCounts.isEmpty && rig.plays == 0 && rig.capture.stopCount == 1)
            adapter.stop()
        }
    }
}
