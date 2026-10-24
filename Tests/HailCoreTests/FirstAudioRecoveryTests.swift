import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825 / #851: another device holds haild's shared audio turn; this device receives no host audio meanwhile.
/// Injected time, synthetic PCM and a fake player only; no physical cross-device playback proof.
@MainActor
@Suite struct FirstAudioRecoveryTests {
    @Test func crossDeviceQueuePlaysLateAudioWithoutAnotherNotice() async throws {
        let rig = IdleRig(), reply = idleReply()
        let renderer = CountingRenderer(), fallback = FirstAudioFallbacks()
        let announcer = Announcer(playback: rig.controller, renderer: renderer) { fallback.record($0, $1) }
        announcer.watchReplyAudio { true }
        rig.controller.ingest(firstAudioText(reply))
        rig.advance(by: .seconds(19))
        #expect(rig.abandoned == 0)
        rig.advance(by: .seconds(1))
        #expect(rig.abandoned == 1)
        #expect(rig.status(of: reply) == ReplyPlaybackController.abandonedStatus)
        // Buffering also covers scheduling before the await; no wall-clock deadline or executor-yield budget.
        _ = await rig.player.scheduledBuffers.stream.first { @Sendable _ in true }
        #expect(rig.player.scheduled.count == 1)
        #expect(renderer.rendered == [.replyAudioLost])
        rig.player.completeReply()
        rig.advance(by: .seconds(40)) // t=60: the other device's turn ends; only now does B's audio reach us.
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 7))
        try #require(rig.player.scheduled.last?.reply?.id == reply.id)
        #expect(rig.player.scheduled.last?.bytes.first == 7)
        #expect(rig.status(of: reply) != ReplyPlaybackController.abandonedStatus)
        rig.player.completeReply()
        #expect(rig.status(of: reply) == "Played")
        #expect(rig.controller.lostAudioStatuses.isEmpty)
        rig.advance(by: .seconds(600))
        await settleFirstAudio()
        #expect(rig.abandoned == 1 && rig.liveDeadlineCount == 0)
        #expect(renderer.rendered == [.replyAudioLost] && fallback.announcements.isEmpty)
        #expect(rig.player.scheduled.count == 2, "only the loss notice and B, with no recovery cue")
        withExtendedLifetime(announcer) {}
    }

    @Test(arguments: [false, true])
    func repeatedExpiredTextNeverRearmsOrRetiresTheReply(refusedAudio: Bool) {
        let rig = IdleRig(), reply = idleReply()
        let key = ReplyStreamKey(endpointID: "main", replyID: reply.id)
        rig.controller.ingest(firstAudioText(reply))
        rig.advance(by: .seconds(20))
        if refusedAudio {
            var event = idleAudio(reply, sequence: 0, final: true, byte: 7)
            if case .audio(var audio) = event.frame.payload {
                audio.codec = .opus
                event.frame.payload = .audio(audio)
            }
            rig.controller.ingest(event)
            #expect(rig.controller.undeliveredLosses.count == 1, "refused audio does not clear a loss")
        }
        // Remove presentation/status as a reason not to re-arm: the bounded identity record must survive trimming.
        rig.controller.acknowledgeAudioLoss(rig.controller.replies[0].id)
        for _ in 0...ReplyPlaybackController.presentationLimit {
            let textOnly = ReplyDescriptor(id: UUID(), hostID: "host", targetID: "target")
            rig.controller.ingest(firstAudioText(textOnly))
        }
        #expect(rig.status(of: reply) == nil)
        for _ in 0..<3 {
            rig.controller.ingest(firstAudioText(reply))
            #expect(rig.liveDeadlineCount == 0)
            rig.advance(by: .seconds(60))
        }
        #expect(rig.abandoned == 1)
        #expect(!rig.controller.completed.contains(key), "a silence claim must leave late audio eligible")
        #expect(rig.player.scheduled.isEmpty)
    }

    @Test(arguments: ["host", "headset", "supersede"])
    func explicitRetirementStillRejectsExpiredAudio(action: String) {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.ingest(firstAudioText(reply))
        rig.advance(by: .seconds(20))
        if action == "host" {
            rig.controller.ingest(firstAudioControl(.stopPlayback))
        } else if action == "headset" {
            rig.controller.stopPlayback(from: nil)
        } else {
            rig.controller.togglePause()
            rig.controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 2))
        }
        #expect(rig.status(of: reply) == (action == "supersede" ? "Skipped" : "Stopped"))
        #expect(rig.controller.completed.contains(ReplyStreamKey(endpointID: "main", replyID: reply.id)))
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 7))
        rig.advance(by: .seconds(60))
        #expect(rig.player.scheduled.allSatisfy { $0.reply?.id != reply.id })
        #expect(rig.abandoned == 1 && rig.liveDeadlineCount == 0)
    }

    @Test func acceptedLateAudioReleasesAnUnannouncedLossAndCanReallyStall() {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.ingest(firstAudioText(reply))
        rig.advance(by: .seconds(20))
        #expect(rig.controller.undeliveredLosses.count == 1)
        #expect(rig.abandoned == 1)
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: false, byte: 7))
        #expect(rig.player.scheduled.last?.reply?.id == reply.id)
        #expect(rig.controller.undeliveredLosses.isEmpty)
        #expect(rig.status(of: reply) != ReplyPlaybackController.abandonedStatus)
        rig.advance(by: .seconds(22)) // 1.25 s of audio, then the existing 20 s mid-stream idle watch.
        #expect(rig.abandoned == 2, "a subsequent mid-stream stall is a separate real loss")
        #expect(rig.controller.undeliveredLosses.count == 1)
        #expect(rig.status(of: reply) == ReplyPlaybackController.abandonedStatus)
    }
}
