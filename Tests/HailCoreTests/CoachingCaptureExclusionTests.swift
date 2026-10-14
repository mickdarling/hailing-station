import Foundation
import Testing
@testable import HailCore

@Suite("App-wide coaching capture admission")
@MainActor
struct CoachingCaptureExclusionTests {
    @Test func pendingStartupAndRetirementHoldAdmission() {
        let gate = CoachingCaptureExclusion()
        let pendingAmbient = UUID(), privateOwner = UUID()
        #expect(gate.claim(pendingAmbient))
        #expect(!gate.claim(privateOwner)) // Permission and streamer construction have not completed.
        #expect(gate.isClaimed)
        #expect(!gate.claim(privateOwner)) // Retirement has started, but has not joined.
        gate.release(pendingAmbient)
        #expect(gate.claim(privateOwner))
    }

    @Test func lateCleanupCannotReleaseAReplacement() {
        let gate = CoachingCaptureExclusion()
        let first = UUID(), replacement = UUID()
        #expect(gate.claim(first))
        #expect(gate.claim(first))
        gate.release(first)
        #expect(gate.claim(replacement))
        gate.release(first)
        #expect(gate.isClaimed)
        #expect(!gate.claim(UUID()))
        gate.release(replacement)
        #expect(!gate.isClaimed)
    }
}
