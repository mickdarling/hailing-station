import Foundation
@testable import HailCore
import Testing

/// Ambient capture and private coaching never hold the microphone together (#645).
@MainActor
@Suite struct PrivateListeningExclusionTests {
    @Test func eachSideRefusesWhileTheOtherHoldsIt() {
        let exclusion = PrivateListeningExclusion()
        #expect(exclusion.claimCoaching())
        #expect(!exclusion.claimAmbient() && !exclusion.ambientOn)
        #expect(!exclusion.claimCoaching()) // One run at a time.
        exclusion.releaseCoaching()
        #expect(exclusion.claimAmbient())
        #expect(!exclusion.claimCoaching())
        exclusion.releaseAmbient()
        #expect(exclusion.claimCoaching())
    }

    @Test func ambientTurnOnIsRefusedBeforeAnyPermissionOrCaptureWhileCoachingHoldsAudio() async throws {
        let harness = AmbientListeningControllerTests.Harness()
        let exclusion = PrivateListeningExclusion()
        harness.controller.exclusion = exclusion
        #expect(exclusion.claimCoaching())
        await harness.controller.turnOn(for: try binding())
        #expect(!harness.controller.isOn && harness.capture.startCount == 0)
        #expect(harness.controller.stopReason != nil)
        #expect(!exclusion.ambientOn)
    }

    @Test func ambientClaimsFromTheRequestSoCoachingCannotStartInItsStartupWindow() async throws {
        let harness = AmbientListeningControllerTests.Harness()
        let exclusion = PrivateListeningExclusion()
        harness.controller.exclusion = exclusion
        await harness.controller.turnOn(for: try binding())
        #expect(exclusion.ambientOn)
        #expect(!exclusion.claimCoaching())
        await harness.controller.turnOff()
        #expect(!exclusion.ambientOn)
        #expect(exclusion.claimCoaching())
    }

    @Test func withoutAnExclusionAmbientIsUnchanged() async throws {
        let harness = AmbientListeningControllerTests.Harness()
        await harness.controller.turnOn(for: try binding())
        #expect(harness.controller.isOn && harness.capture.startCount == 1)
        await harness.controller.turnOff()
    }
}
