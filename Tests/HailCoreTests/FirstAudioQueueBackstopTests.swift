import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825: synthetic host audio queues, injected idle time and a fake player; no physical playback proof.
@MainActor
@Suite struct FirstAudioQueueBackstopTests {
    @Test func continuousOtherRepliesLosePendingAudioAtTenMinutes() throws {
        let rig = IdleRig(), waiting = idleReply()
        playOtherReply(rig)
        rig.advance(by: .seconds(1))
        rig.controller.ingest(firstAudioText(waiting)) // t=1: the hard cap must be t=601, not t=600.
        rig.advance(by: .seconds(2))
        for sequence in 1...200 { // Back-to-back other replies at t=3...600, never 20 seconds of host silence.
            playOtherReply(rig)
            if sequence == 100 { rig.controller.ingest(firstAudioText(waiting)) }
            #expect(rig.abandoned == 0)
            #expect(rig.liveDeadlineCount == 1, "each frame replaces the pending timer")
            if sequence < 200 { rig.advance(by: .seconds(3)) }
        }
        rig.advance(by: .milliseconds(900))
        #expect(rig.abandoned == 0)
        #expect(rig.status(of: waiting) == "Received")
        rig.advance(by: .milliseconds(100)) // Exactly ten minutes since B's original text.
        #expect(rig.abandoned == 1)
        #expect(rig.status(of: waiting) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.liveDeadlineCount == 0)
        for _ in 0..<20 { // Continue E's other replies through t=661: eleven minutes since B's text.
            rig.advance(by: .seconds(3))
            playOtherReply(rig)
        }
        rig.controller.ingest(firstAudioText(waiting))
        rig.controller.ingest(idleAudio(waiting, sequence: 0, final: true, byte: 2))
        #expect(rig.abandoned == 1)
        #expect(rig.liveDeadlineCount == 0)
        try #require(rig.player.scheduled.last?.reply?.id == waiting.id)
        rig.player.completeReply()
        #expect(rig.status(of: waiting) == "Played")
    }

    @Test func audioQueuedBehindNineMinutesStillPlays() throws {
        let rig = IdleRig(), playing = idleReply(), waiting = idleReply()
        rig.controller.ingest(idleAudio(playing, sequence: 0, final: false, byte: 1))
        rig.advance(by: .seconds(1))
        rig.controller.ingest(firstAudioText(waiting))
        rig.advance(by: .seconds(2))
        for sequence in 1...180 { // One A frame every three seconds until t=540.
            rig.controller.ingest(idleAudio(playing, sequence: sequence, final: sequence == 180, byte: 1))
            if sequence < 180 { rig.advance(by: .seconds(3)) }
        }
        rig.player.completeReply()
        rig.advance(by: .seconds(1)) // B has waited nine minutes since its text at t=1.
        #expect(rig.abandoned == 0)
        #expect(rig.status(of: waiting) == "Received")
        rig.controller.ingest(idleAudio(waiting, sequence: 0, final: true, byte: 2))
        try #require(rig.player.scheduled.last?.reply?.id == waiting.id)
        #expect(rig.player.scheduled.last?.bytes.first == 2)
        rig.player.completeReply()
        #expect(rig.status(of: waiting) == "Played")
        rig.advance(by: .seconds(120))
        #expect(rig.abandoned == 0)
        #expect(rig.liveDeadlineCount == 0)
    }

    @Test(arguments: [false, true])
    func confirmClipCountsAsHostActivity(includesText: Bool) {
        let rig = IdleRig(), waiting = idleReply(), clip = idleReply()
        rig.controller.ingest(firstAudioText(waiting))
        rig.advance(by: .seconds(10))
        // confirm-* is a host clip directory, not wire metadata: acknowledgementFrames sends a request-less
        // reply with an optional text and a final PCM frame, with its own reply id on the same endpoint.
        if includesText { rig.controller.ingest(firstAudioText(clip)) }
        rig.controller.ingest(idleAudio(clip, sequence: 0, final: true, byte: 3))
        #expect(rig.player.scheduled.last?.reply?.id == clip.id)
        rig.player.completeReply()
        rig.advance(by: .seconds(10)) // Original deadline, while the clip extended it to t=30.
        #expect(rig.abandoned == 0)
        #expect(rig.status(of: waiting) == "Received")
        #expect(rig.liveDeadlineCount == 1)
        rig.advance(by: .milliseconds(9_900))
        #expect(rig.abandoned == 0)
        rig.advance(by: .milliseconds(100))
        #expect(rig.abandoned == 1)
        #expect(rig.status(of: waiting) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.liveDeadlineCount == 0)
        rig.advance(by: .seconds(600))
        #expect(rig.abandoned == 1)
    }

    private func playOtherReply(_ rig: IdleRig) {
        rig.controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 1))
        rig.player.completeReply()
    }
}
