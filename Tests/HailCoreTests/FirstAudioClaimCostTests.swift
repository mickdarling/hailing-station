import Foundation
@testable import HailCore
import Testing

#if DEBUG
/// #825: count dictionary probes, never wall time. Large setup contains no timers or playback.
@MainActor
@Suite struct FirstAudioClaimCostTests {
    @Test func expiryMembershipWorkDoesNotGrowWithHistory() {
        #expect(expiryLookups(historyCount: 4) == expiryLookups(historyCount: 1_024))
    }

    private func expiryLookups(historyCount: Int) -> Int {
        let rig = IdleRig()
        rig.controller.firstAudioClaimLimit = historyCount
        // Seed exactly the membership state at expiry; omit presentation history and timer iteration.
        for _ in 0..<historyCount {
            let key = ReplyStreamKey(endpointID: "main", replyID: UUID())
            rig.controller.expiredFirstAudio.append(key)
            rig.controller.undeliveredLosses.append(key)
        }
        let reply = idleReply()
        rig.controller.ingest(firstAudioText(reply))
        let before = rig.controller.expiredFirstAudio.membershipLookups
            + rig.controller.undeliveredLosses.membershipLookups
        rig.advance(by: .seconds(20))
        #expect(rig.abandoned == 1)
        let work = rig.controller.expiredFirstAudio.membershipLookups
            + rig.controller.undeliveredLosses.membershipLookups - before
        #expect(work == 4, "two inserts, oldest eviction and loss removal; no history scan")
        return work
    }
}
#endif
