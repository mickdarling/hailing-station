import Foundation
import Testing
@testable import HailCore

/// #269/#225: production composition exercised without instantiating live audio hardware.
@Suite @MainActor struct ApplePrivateCoachingTests {
    @Test func constructorAndMissingConsentNeverStartCapture() throws {
        let rig = AppleCoachingRig()
        let adapter = try rig.make()
        #expect(rig.capture.startCount == 0 && rig.frameCounts.isEmpty)
        #expect(throws: CoachingSafetyError.consentRequired) {
            try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: false)
        }
        #expect(rig.capture.startCount == 0)
    }

    @Test func bluetoothAndUnknownOutputsFailBeforeMicrophoneStartup() throws {
        for kind in [AudioOutputKind.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .other, .builtInSpeaker] {
            let rig = AppleCoachingRig()
            rig.outputs = [.init(uid: "synthetic-not-headphones", kind: kind)]
            let adapter = try rig.make()
            #expect(throws: CoachingSafetyError.unsafeOutput) {
                try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
            }
            #expect(rig.capture.startCount == 0 && rig.frameCounts.isEmpty)
        }
    }

    @Test func qualifiedWiredCompositionForwardsUnmaskedCaptureDuringAdvice() async throws {
        let rig = AppleCoachingRig()
        let adapter = try rig.make()
        let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try adapter.admit(coachingWireData(lease))
        try adapter.schedule(coachingPCM, for: advice)
        try rig.capture.yield(sineBuffer())
        await drainCoachingTasks()
        #expect(rig.captureBuffers == 1 && rig.nonzeroCapture && rig.frameCounts == [2] && rig.plays == 1)
        adapter.stop()
    }

    @Test func lifecycleLossFencesRendererBeforeActorDelayedCleanupAndCannotReviveOldWork() async throws {
        let rig = AppleCoachingRig()
        let adapter = try rig.make()
        let old = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try adapter.admit(coachingWireData(old))
        rig.center.post(name: rig.event, object: nil)
        #expect(throws: CoachingWireError.staleAdvice) { try adapter.resume(advice) }
        #expect(rig.capture.stopCount == 1 && rig.frameCounts.isEmpty)
        await drainCoachingTasks()
        let fresh = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        #expect(fresh.generation != old.generation)
        #expect(throws: CoachingWireError.staleAdvice) { try adapter.schedule(coachingPCM, for: advice) }
        adapter.stop()
    }

    @Test func connectionLossStopsOwnedCaptureAndClearsDownstreamContextOnce() throws {
        let rig = AppleCoachingRig()
        let adapter = try rig.make()
        let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try adapter.admit(coachingWireData(lease))
        adapter.invalidate()
        adapter.invalidate()
        #expect(rig.capture.stopCount == 1 && rig.suspensions == [.routeInvalidated])
        #expect(throws: CoachingWireError.staleAdvice) { try adapter.setMuted(false, for: advice) }
    }

    @Test func originalExpiryAndReleaseStopOwnedResources() throws {
        for release in [false, true] {
            let rig = AppleCoachingRig()
            var adapter: ApplePrivateCoaching? = try rig.make()
            _ = try #require(adapter).begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
            if release { adapter = nil } else { rig.time.advance(.seconds(2)) }
            #expect(rig.capture.stopCount == 1 && rig.suspensions.count == 1)
            #expect(rig.frameCounts.isEmpty)
        }
    }

    @Test func routeLossDuringCaptureStartAndPartialStartupFailureAreRetired() throws {
        for fails in [false, true] {
            let rig = AppleCoachingRig()
            let capture = CoachingStartingCapture()
            capture.fails = fails
            if !fails { capture.onStart = { rig.center.post(name: rig.event, object: nil) } }
            let adapter = try rig.make(capture: capture)
            let expected: CoachingSafetyError = fails ? .invalidAudio : .unsafeOutput
            #expect(throws: expected) {
                try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
            }
            #expect(capture.base.startCount == 1 && capture.base.stopCount == 1)
            #expect(rig.monitor.observe() == .unqualified && rig.frameCounts.isEmpty)
        }
    }
}
