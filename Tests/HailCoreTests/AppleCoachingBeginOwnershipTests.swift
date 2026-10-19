import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct AppleCoachingBeginOwnershipTests {
    @Test(arguments: [5, 6])
    func staleBeginRegistrationCannotStopItsRenewedLease(trigger: Int) throws {
        let rig = AppleCoachingRig()
        let adapter = try rig.make()
        // Read the actual owned core only in this authored fixture, without adding a production accessor.
        let core = try #require(Mirror(reflecting: adapter).children.compactMap {
            $0.value as? PrivateCoachingSession
        }.first)
        var observations = 0
        var renewed: CoachingQualification?
        rig.onSnapshot = {
            observations += 1
            guard observations == trigger else { return }
            rig.onSnapshot = nil
            do { renewed = try adapter.renew(#require(core.qualification)) } catch { Issue.record(error) }
        }
        #expect(throws: (any Error).self) {
            try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        }
        let lease = try #require(renewed)
        #expect(core.qualification == lease && rig.capture.startCount == 1 && rig.capture.stopCount == 0)
        #expect(rig.suspensions.isEmpty)
        let advice = try adapter.admit(coachingWireData(lease))
        try adapter.schedule(coachingPCM, for: advice)
        #expect(rig.plays == 1 && rig.frameCounts == [2])
        adapter.stop()
    }

    @Test func suspendedHookCannotPublishANestedBeginDuringCoreRetirement() throws {
        let rig = AppleCoachingRig()
        let adapter = try rig.make()
        _ = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        var rejected = false
        rig.onSuspended = {
            rig.onSuspended = nil
            do {
                _ = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
                Issue.record("Nested Begin published during core retirement")
            } catch CoachingSafetyError.transitionInProgress { rejected = true } catch { Issue.record(error) }
        }
        let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        #expect(rejected && rig.capture.startCount == 2 && rig.capture.stopCount == 1)
        let advice = try adapter.admit(coachingWireData(lease))
        try adapter.schedule(coachingPCM, for: advice)
        #expect(rig.plays == 1)
        adapter.stop()
    }
}
