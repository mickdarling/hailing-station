#if os(macOS)
import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct MacCoachingFinalReadinessTests {
    @Test(arguments: 0..<3, 0..<3)
    func finalReadinessCannotControlReplacementExpiredOrInvalidatedLifetime(action: Int, mutation: Int) throws {
        let rig = MacCoachingCompositionRig()
        let adapter = try rig.make()
        let old = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try adapter.admit(coachingWireData(old))
        var freshAdvice: AdmittedCoachingAdvice?
        var reads = 0
        rig.onReady = {
            reads += 1
            guard reads == 2 else { return }
            rig.onReady = nil
            switch mutation {
            case 0: rig.time.instant = old.expiresAt
            case 1:
                do {
                    let fresh = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
                    let admitted = try adapter.admit(coachingWireData(fresh))
                    try adapter.schedule(coachingPCM, for: admitted)
                    freshAdvice = admitted
                } catch { Issue.record(error) }
            default: rig.propertyChanged?() // Calling-thread latch retires before actor cleanup.
            }
        }
        #expect(throws: (any Error).self) {
            switch action {
            case 0: try adapter.schedule(coachingPCM, for: advice)
            case 1: try adapter.resume(advice)
            default: try adapter.setMuted(false, for: advice)
            }
        }
        #expect(rig.mutes.isEmpty && rig.capture.stopCount == 1 && rig.stops == 1)
        if mutation == 1 {
            #expect(rig.starts == 2 && rig.capture.startCount == 2 && rig.plays == 1 && rig.queued == 1)
            #expect(rig.suspensions == [.stopped])
            try adapter.resume(try #require(freshAdvice))
        } else {
            #expect(rig.plays == 0 && rig.queued == 0 && rig.starts == 1)
            // Throwing player operations retire as playback failure before queued route cleanup;
            // mute's nonthrowing protocol reports its denial through the adapter invalidation hook.
            #expect(rig.suspensions == [reason(action: action, mutation: mutation)])
        }
        adapter.stop()
    }

    private func reason(action: Int, mutation: Int) -> CoachingSuspension {
        mutation == 0 ? .qualificationExpired : (action == 2 ? .routeInvalidated : .playbackFailed)
    }
}
#endif
