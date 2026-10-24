import Foundation
@testable import HailCore
import HailProtocol
import Testing

#if DEBUG
/// #825: count visited presentation identities and Sequence elements, never wall time or lookup calls.
@MainActor
@Suite struct FirstAudioClaimCostTests {
    @Test func expiryTraversalDoesNotGrowWithHistory() {
        #expect(expiryTraversal(historyCount: 4) == expiryTraversal(historyCount: 1_024))
    }

    private func expiryTraversal(historyCount: Int) -> Int {
        let rig = IdleRig(), controller = rig.controller
        controller.firstAudioClaimLimit = historyCount
        // Ordinary history starts at the trim limit; pending and unacknowledged claims remain pinned.
        for _ in 0..<ReplyPlaybackController.presentationLimit {
            controller.ingest(firstAudioText(ReplyDescriptor(id: UUID(), hostID: "host", targetID: "target")))
        }
        for _ in 0..<historyCount {
            let reply = idleReply(), key = ReplyStreamKey(endpointID: "main", replyID: reply.id)
            controller.ingest(firstAudioText(reply))
            controller.cancelFirstAudio(for: [key])
            controller.expiredFirstAudio.append(key)
            controller.recordAudioLoss(for: key)
        }
        for _ in 0..<historyCount { controller.ingest(firstAudioText(idleReply())) }
        let reply = idleReply(), key = ReplyStreamKey(endpointID: "main", replyID: reply.id)
        controller.ingest(firstAudioText(reply))
        #expect(controller.replies.count >= ReplyPlaybackController.presentationLimit)
        #expect(controller.firstAudio.count == historyCount + 1)
        #expect(controller.expiredFirstAudio.count == historyCount)
        #expect(controller.undeliveredLosses.count == historyCount)
        let visits = ClaimTraversalCount()
        // Measure only one due claim, excluding setup, fake-clock timer iteration and assertion scans.
        controller.idleNow = { .now.advanced(by: .seconds(21)) }
        ReplyTraversal.$onVisit.withValue({ visits.increment() }, operation: {
            controller.firstAudioDeadlinePassed(for: key)
        })
        let work = visits.value
        #expect(rig.abandoned == 1)
        #expect(controller.presentationStatuses[key.presentationID] == ReplyPlaybackController.abandonedStatus)
        #expect(controller.completed.count == 1, "the oldest expired claim was evicted")
        #expect(work == 0, "expiry must visit no presentation history or claim-window elements")
        // Positive controls prove that ordinary Array searches and Sequence scans really hit the hook.
        ReplyTraversal.$onVisit.withValue({ visits.increment() }, operation: {
            #expect(controller.replies.first { $0.id == key.presentationID } != nil)
            #expect(controller.undeliveredLosses.contains { $0 == key })
        })
        #expect(visits.value - work >= controller.replies.count + historyCount)
        return work
    }
}

/// Shared only by the scoped Sendable callback; no mutable captured locals or global counters.
private final class ClaimTraversalCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
#endif
