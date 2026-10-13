import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct CoachingPlaybackObservationTests {
    @Test func offUnknownAndExpiryAreNotIdleWhileOwnedCompletedQueueIsIdle() throws {
        let rig = AppleCoachingRig(), player = CoachingTestPlayer()
        let owner = try ApplePrivateCoaching(capture: rig.capture, player: player, monitor: rig.monitor,
            listenerID: "private-coach", hooks: .init(buffer: { _, _ in }, suspended: { _, _ in }),
            clock: rig.time.clock)
        #expect(owner.privatePlaybackObservation() == .unavailable)
        let lease = try owner.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        #expect(owner.privatePlaybackObservation() == .idle)
        let advice = try owner.admit(coachingWireData(lease))
        try owner.schedule(coachingPCM, for: advice)
        #expect(owner.privatePlaybackObservation() == .pending)
        try owner.setMuted(true, for: advice)
        #expect(owner.privatePlaybackObservation() == .pending)
        player.completions[0]()
        #expect(owner.privatePlaybackObservation() == .idle)
        rig.time.advance(.seconds(2))
        #expect(owner.privatePlaybackObservation() == .unavailable && rig.capture.stopCount == 1)
    }

    @Test func observationCallbackRetirementCannotReportIdle() throws {
        let rig = AppleCoachingRig(), owner = try rig.make()
        _ = try owner.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        rig.onSnapshot = { owner.stop() }
        #expect(owner.privatePlaybackObservation() == .unavailable)
        #expect(rig.capture.stopCount == 1)
    }

    @Test func finalClockCallbackRetirementCannotReportIdle() throws {
        let rig = AppleCoachingRig(), owner = try rig.make()
        _ = try owner.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        rig.time.onNow = { owner.stop() }
        #expect(owner.privatePlaybackObservation() == .unavailable && rig.capture.stopCount == 1)
    }
}
