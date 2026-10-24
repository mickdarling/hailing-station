import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825 round 2: presentation pressure and mute must not erase pending reply lifecycle state.
@MainActor
@Suite struct ReplyPlaybackFirstAudioReviewTests {
    @Test(arguments: [false, true])
    func pendingLossSurvivesPresentationPressure(promisedFillers: Bool) async throws {
        let rig = IdleRig(), reply = idleReply()
        let renderer = CountingRenderer(), fallback = FirstAudioFallbacks()
        let observed = ObservedReplyLosses()
        let announcer = Announcer(playback: rig.controller, renderer: renderer) { fallback.record($0, $1) }
        announcer.watchReplyAudio { observed.record(rig.controller); return true }
        rig.controller.ingest(firstAudioText(reply))
        let id = try #require(rig.controller.replies.first?.id)
        for _ in 0...ReplyPlaybackController.presentationLimit {
            let filler = promisedFillers ? idleReply()
                : ReplyDescriptor(id: UUID(), hostID: "host", targetID: "target")
            rig.controller.ingest(firstAudioText(filler))
        }
        let expected = promisedFillers ? ReplyPlaybackController.presentationLimit + 2 : 1
        #expect(rig.liveDeadlineCount == expected)
        await settleFirstAudio() // re-arm observation after the history updates
        rig.advance(by: .seconds(20))
        rig.controller.ingest(lossRaceText()) // queued before the Announcer can observe expiry
        #expect(rig.controller.lostAudioStatuses[id] == ReplyPlaybackController.abandonedStatus)
        #expect(rig.controller.lostAudioStatuses.count == expected)
        #expect(rig.abandoned == expected)
        await settleFirstAudio()
        #expect(renderer.rendered == Array(repeating: .replyAudioLost, count: expected))
        #expect(rig.player.scheduled.last?.isFinal == true, "the loss cue reaches the reply player")
        #expect(fallback.announcements.isEmpty)
        playLossCues(rig, count: expected)
        #expect(observed.statuses.count == expected)
        #expect(observed.statuses[id] == ReplyPlaybackController.abandonedStatus)
        #expect(rig.controller.presentationKeysToRetain.isEmpty, "every observed loss was acknowledged")
        announcer.watchReplyAudio { true }
        await settleFirstAudio()
        #expect(renderer.rendered.count == expected, "each expired reply is announced exactly once")
        withExtendedLifetime(announcer) {}
    }

    @Test(arguments: [false, true])
    func repeatedTextAfterMuteNeverRearmsButNormalAudioStillArrives(pendingVoiceMute: Bool) {
        let (rig, reply) = mutedPendingReply(pendingVoiceMute)
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: false)))
        rig.controller.ingest(firstAudioText(reply)) // same reply, new frame ID
        #expect(rig.liveDeadlineCount == 0)
        rig.advance(by: .seconds(60))
        #expect(rig.abandoned == 0)
        #expect(rig.controller.lostAudioStatuses.isEmpty)
        #expect(rig.status(of: reply) == "Received")
        if pendingVoiceMute { rig.player.completeReply() }
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 7))
        #expect(rig.player.scheduled.last?.bytes.first == 7)
    }

    @Test(arguments: [false, true])
    func hostStopRetiresMutedPendingReply(pendingVoiceMute: Bool) {
        let (rig, reply) = mutedPendingReply(pendingVoiceMute)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        #expect(rig.status(of: reply) == "Stopped")
        let scheduled = rig.player.scheduled.count
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: false)))
        rig.controller.ingest(firstAudioText(reply))
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 7))
        rig.advance(by: .seconds(60))
        #expect(rig.player.scheduled.count == scheduled)
        #expect(rig.status(of: reply) == "Stopped")
        #expect(rig.abandoned == 0)
    }

    @Test(arguments: [false, true])
    func supersessionRetiresMutedPendingReply(pendingVoiceMute: Bool) {
        let (rig, reply) = mutedPendingReply(pendingVoiceMute)
        rig.controller.togglePause()
        let replacement = idleReply()
        rig.controller.ingest(idleAudio(replacement, sequence: 0, final: true, byte: 2))
        #expect(rig.status(of: reply) == "Skipped")
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: false)))
        if pendingVoiceMute { rig.player.completeReply() } // cancelled old callback cannot finish the replacement
        rig.player.completeReply()
        let scheduled = rig.player.scheduled.count
        rig.controller.ingest(firstAudioText(reply))
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 7))
        rig.advance(by: .seconds(60))
        #expect(rig.player.scheduled.count == scheduled)
        #expect(rig.status(of: reply) == "Skipped")
        #expect(rig.abandoned == 0)
    }

    @Test func mutedPendingStateHasABoundedWindowAndRetiresOverflow() {
        let rig = IdleRig()
        rig.controller.firstAudioClaimLimit = 4
        rig.controller.toggleMute()
        let replies = (0...rig.controller.firstAudioClaimLimit).map { _ in idleReply() }
        for reply in replies { rig.controller.ingest(firstAudioText(reply)) }
        // The bounded pending window retires overflow rather than forgetting it and permitting a re-arm.
        #expect(rig.controller.completed.count == 1)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        #expect(rig.controller.completed.count == replies.count)
        rig.controller.toggleMute()
        for reply in replies {
            rig.controller.ingest(firstAudioText(reply))
            rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 7))
        }
        rig.advance(by: .seconds(60))
        #expect(rig.liveDeadlineCount == 0)
        #expect(rig.player.scheduled.isEmpty)
        #expect(rig.abandoned == 0)
    }

    private func mutedPendingReply(_ pendingVoiceMute: Bool) -> (IdleRig, ReplyDescriptor) {
        let rig = IdleRig(), reply = idleReply()
        if pendingVoiceMute {
            rig.controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 1))
        }
        rig.controller.ingest(firstAudioText(reply))
        #expect(rig.liveDeadlineCount == 1)
        if pendingVoiceMute {
            rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        } else {
            rig.controller.toggleMute()
        }
        #expect(rig.liveDeadlineCount == 0)
        return (rig, reply)
    }
}
