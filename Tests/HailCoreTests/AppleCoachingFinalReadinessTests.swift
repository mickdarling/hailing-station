import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct AppleCoachingFinalReadinessTests {
    @Test(arguments: 0..<3, [false, true])
    func finalReadinessCannotControlReplacementOrCrossOriginalDeadline(action: Int, expires: Bool) throws {
        let rig = AppleCoachingRig()
        let adapter = try rig.make()
        let old = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let oldAdvice = try adapter.admit(coachingWireData(old))
        var freshAdvice: AdmittedCoachingAdvice?
        var reads = 0
        rig.onReady = {
            reads += 1
            guard reads == 2 else { return }
            rig.onReady = nil
            if expires { rig.time.instant = old.expiresAt; return }
            do {
                let fresh = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
                let advice = try adapter.admit(coachingWireData(fresh))
                try adapter.schedule(coachingPCM, for: advice)
                freshAdvice = advice
            } catch { Issue.record(error) }
        }
        #expect(throws: (any Error).self) {
            switch action {
            case 0: try adapter.schedule(coachingPCM, for: oldAdvice)
            case 1: try adapter.resume(oldAdvice)
            default: try adapter.setMuted(false, for: oldAdvice)
            }
        }
        #expect(rig.capture.stopCount == 1)
        #expect(rig.mutes.isEmpty)
        if expires {
            #expect(rig.plays == 0 && rig.frameCounts.isEmpty && rig.suspensions == [.qualificationExpired])
        } else {
            #expect(rig.capture.startCount == 2 && rig.plays == 1 && rig.frameCounts == [2])
            #expect(rig.suspensions == [.stopped])
            try adapter.resume(try #require(freshAdvice))
        }
        adapter.stop()
    }
}
