import Foundation
@testable import HailCore
import Testing

/// Ambient capture and private coaching never hold the microphone together (#645).
@MainActor
@Suite struct PrivateListeningExclusionTests {
    @Test func eachSideRefusesWhileTheOtherHoldsIt() throws {
        let exclusion = PrivateListeningExclusion()
        let coaching = try #require(exclusion.claimCoaching())
        #expect(exclusion.claimAmbient() == nil && !exclusion.ambientOn)
        #expect(exclusion.claimCoaching() == nil) // One run at a time.
        exclusion.releaseCoaching(coaching)
        let ambient = try #require(exclusion.claimAmbient())
        #expect(exclusion.claimCoaching() == nil)
        exclusion.releaseAmbient(ambient)
        #expect(exclusion.claimCoaching() != nil)
    }

    @Test func aStaleReleaseCannotClearANewerClaim() throws {
        let exclusion = PrivateListeningExclusion()
        let first = try #require(exclusion.claimCoaching())
        exclusion.releaseCoaching(first)
        let second = try #require(exclusion.claimCoaching())
        exclusion.releaseCoaching(first) // A late release from the earlier run.
        #expect(exclusion.coachingHoldsAudio && exclusion.claimAmbient() == nil)
        exclusion.releaseCoaching(second)
        let ambient = try #require(exclusion.claimAmbient())
        exclusion.releaseAmbient(UUID())
        #expect(exclusion.ambientOn)
        exclusion.releaseAmbient(ambient)
        #expect(!exclusion.ambientOn)
    }

    @Test func ambientTurnOnIsRefusedBeforeAnyPermissionOrCaptureWhileCoachingHoldsAudio() async throws {
        let harness = AmbientListeningControllerTests.Harness()
        let exclusion = PrivateListeningExclusion()
        harness.controller.exclusion = exclusion
        #expect(exclusion.claimCoaching() != nil)
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
        #expect(exclusion.claimCoaching() == nil)
        await harness.controller.turnOff()
        #expect(!exclusion.ambientOn)
        #expect(exclusion.claimCoaching() != nil)
    }

    @Test func withoutAnExclusionAmbientIsUnchanged() async throws {
        let harness = AmbientListeningControllerTests.Harness()
        await harness.controller.turnOn(for: try binding())
        #expect(harness.controller.isOn && harness.capture.startCount == 1)
        await harness.controller.turnOff()
    }
}
