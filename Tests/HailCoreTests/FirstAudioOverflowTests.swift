import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825: bounded first-audio history retires overflow instead of forgetting a playable reply's identity.
/// Injected time and synthetic PCM only; no physical playback proof.
@MainActor
@Suite struct FirstAudioOverflowTests {
    @Test func overflowedTextCannotRearmAfterPresentationTrimming() {
        let history = ExpiredAudioHistory(), rig = history.rig
        #expect(rig.controller.completed.contains(history.oldestKey))
        #expect(rig.status(of: history.oldest) == "Skipped")
        // Clear the old loss and trim its presentation, so only lifecycle identity can prevent re-arming.
        rig.controller.acknowledgeAudioLoss("main|\(history.oldest.id.uuidString.lowercased())")
        for _ in 0...ReplyPlaybackController.presentationLimit {
            rig.controller.ingest(firstAudioText(ReplyDescriptor(id: UUID(), hostID: "host", targetID: "target")))
        }
        #expect(rig.status(of: history.oldest) == nil)
        for _ in 0..<3 {
            rig.controller.ingest(firstAudioText(history.oldest))
            #expect(rig.liveDeadlineCount == 0)
            #expect(rig.controller.firstAudioByEndpoint.isEmpty)
            rig.advance(by: .seconds(20))
        }
        #expect(rig.abandoned == history.replies.count, "repeated text must not claim silence again")
        #expect(rig.player.scheduled.isEmpty)
    }

    @Test func overflowedPCMIsSkippedButRetainedExpiredPCMStillPlays() throws {
        let history = ExpiredAudioHistory(), rig = history.rig
        #expect(rig.status(of: history.oldest) == "Skipped")
        rig.controller.ingest(idleAudio(history.oldest, sequence: 0, final: true, byte: 7))
        #expect(rig.player.scheduled.isEmpty)
        #expect(rig.status(of: history.oldest) == "Skipped")
        let retained = try #require(history.replies.last)
        let retainedKey = ReplyStreamKey(endpointID: "main", replyID: retained.id)
        #expect(rig.controller.expiredFirstAudio.contains(retainedKey))
        #expect(!rig.controller.completed.contains(retainedKey))
        rig.controller.ingest(idleAudio(retained, sequence: 0, final: true, byte: 8))
        try #require(rig.player.scheduled.last?.reply?.id == retained.id)
        rig.player.completeReply()
        #expect(rig.status(of: retained) == "Played")
        #expect(rig.player.scheduled.count == 1)
        #expect(rig.abandoned == history.replies.count)
    }

    @Test(arguments: ["host", "headset", "supersede"])
    func explicitRetirementCoversEveryExpiredReplyAfterOverflow(action: String) {
        let history = ExpiredAudioHistory(), rig = history.rig
        let replacement = idleReply()
        #expect(rig.status(of: history.oldest) == "Skipped", "overflow already retired this reply")
        if action == "host" {
            rig.controller.ingest(firstAudioControl(.stopPlayback))
        } else if action == "headset" {
            rig.controller.stopPlayback(from: nil)
        } else {
            rig.controller.togglePause()
            rig.controller.ingest(idleAudio(replacement, sequence: 0, final: true, byte: 2))
        }
        #expect(rig.controller.expiredFirstAudio.isEmpty)
        #expect(history.replies.allSatisfy {
            rig.controller.completed.contains(ReplyStreamKey(endpointID: "main", replyID: $0.id))
        })
        #expect(history.replies.dropFirst().allSatisfy {
            rig.status(of: $0) == (action == "supersede" ? "Skipped" : "Stopped")
        })
        for reply in history.replies {
            rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 7))
        }
        #expect(rig.player.scheduled.allSatisfy { $0.reply?.id == replacement.id })
        #expect(rig.player.scheduled.count == (action == "supersede" ? 1 : 0))
        #expect(rig.abandoned == history.replies.count && rig.liveDeadlineCount == 0)
    }
}

@MainActor
private struct ExpiredAudioHistory {
    let rig = IdleRig()
    let oldest = idleReply()
    let replies: [ReplyDescriptor]
    var oldestKey: ReplyStreamKey { ReplyStreamKey(endpointID: "main", replyID: oldest.id) }

    init() {
        replies = [oldest] + (0..<ReplyPlaybackController.seenFrameLimit).map { _ in idleReply() }
        rig.controller.ingest(firstAudioText(oldest))
        rig.advance(by: .seconds(20))
        // Expire the oldest first, then 1,024 later claims: deterministic oldest-first overflow.
        for reply in replies.dropFirst() { rig.controller.ingest(firstAudioText(reply)) }
        rig.advance(by: .seconds(20))
        #expect(rig.abandoned == replies.count)
        #expect(rig.controller.expiredFirstAudio.count == ReplyPlaybackController.seenFrameLimit)
        #expect(!rig.controller.expiredFirstAudio.contains(oldestKey))
        #expect(rig.liveDeadlineCount == 0)
    }
}
