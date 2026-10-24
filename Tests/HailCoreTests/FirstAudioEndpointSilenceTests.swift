import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825: haild sends text before waiting for its per-endpoint audio turn. Synthetic clocks and player only.
@MainActor
@Suite struct FirstAudioEndpointSilenceTests {
    @Test func queuedAudioAfterSixtySecondStreamIsAccepted() {
        let rig = IdleRig(), playing = idleReply(), waiting = idleReply()
        startQueuedReply(rig, playing: playing, waiting: waiting)
        finishLongStream(rig, playing: playing)
        rig.advance(by: .seconds(5)) // t=65: the next host audio turn starts.
        #expect(rig.abandoned == 0)
        #expect(rig.status(of: waiting) == "Received")
        rig.controller.ingest(idleAudio(waiting, sequence: 0, final: true, byte: 2))
        #expect(rig.player.scheduled.last?.reply?.id == waiting.id)
        #expect(rig.player.scheduled.last?.bytes.first == 2)
        #expect(rig.liveDeadlineCount == 0)
        rig.advance(by: .seconds(60))
        #expect(rig.abandoned == 0)
    }

    @Test func silentQueuedAudioIsClaimedOnceAndCanPlayLate() throws {
        let rig = IdleRig(), playing = idleReply(), waiting = idleReply()
        startQueuedReply(rig, playing: playing, waiting: waiting)
        finishLongStream(rig, playing: playing)
        rig.advance(by: .milliseconds(19_900)) // t=79.9, not t=21 after the text.
        #expect(rig.abandoned == 0)
        #expect(rig.status(of: waiting) == "Received")
        #expect(rig.liveDeadlineCount == 1)
        rig.advance(by: .milliseconds(100))
        #expect(rig.abandoned == 1)
        #expect(rig.status(of: waiting) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.liveDeadlineCount == 0)
        rig.controller.ingest(firstAudioText(waiting))
        rig.controller.ingest(idleAudio(waiting, sequence: 0, final: true, byte: 2))
        rig.advance(by: .seconds(60))
        #expect(rig.abandoned == 1)
        try #require(rig.player.scheduled.last?.reply?.id == waiting.id)
        rig.player.completeReply()
        #expect(rig.status(of: waiting) == "Played")
    }

    @Test func onlyMatchingEndpointCanExtendPendingAudio() {
        for endpoint in ["main", "other"] {
            let rig = IdleRig(), playing = idleReply(), waiting = idleReply()
            rig.controller.ingest(firstAudioText(waiting))
            for sequence in 0...6 {
                if sequence > 0 { rig.advance(by: .seconds(3)) }
                rig.controller.ingest(idleAudio(playing, sequence: sequence, final: false, byte: 1, endpoint: endpoint))
            }
            rig.advance(by: .milliseconds(1_900))
            #expect(rig.abandoned == 0)
            rig.advance(by: .milliseconds(100)) // E's t=20, while the source endpoint is still streaming.
            #expect(rig.abandoned == (endpoint == "main" ? 0 : 1))
            let expected = endpoint == "main" ? "Received" : ReplyPlaybackController.abandonedStatus
            #expect(rig.status(of: waiting) == expected)
            rig.controller.ingest(idleAudio(playing, sequence: 7, final: true, byte: 1, endpoint: endpoint))
            rig.advance(by: .milliseconds(19_900))
            #expect(rig.abandoned == (endpoint == "main" ? 0 : 1))
            rig.advance(by: .milliseconds(100))
            #expect(rig.abandoned == 1)
            #expect(rig.status(of: waiting) == ReplyPlaybackController.abandonedStatus)
            rig.advance(by: .seconds(60))
            #expect(rig.abandoned == 1)
            #expect(rig.liveDeadlineCount == 0)
        }
    }

    @Test(arguments: ["completed", "duplicate", "descriptorless", "refused"])
    func everyIngressExtendsAllPendingWatches(kind: String) {
        let rig = IdleRig(), playing = idleReply(), first = idleReply(), second = idleReply()
        let final = idleAudio(playing, sequence: 0, final: true, byte: 1)
        rig.controller.ingest(final)
        rig.player.completeReply()
        rig.controller.ingest(firstAudioText(first))
        rig.controller.ingest(firstAudioText(second))
        rig.advance(by: .seconds(10))
        rig.controller.ingest(activityFrame(kind, reply: playing, duplicate: final))
        #expect(rig.liveDeadlineCount == 2, "rescheduling replaces both old timers")
        rig.advance(by: .milliseconds(19_900))
        #expect(rig.abandoned == 0)
        rig.advance(by: .milliseconds(100))
        #expect(rig.abandoned == 2)
        #expect(rig.status(of: first) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.status(of: second) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.liveDeadlineCount == 0)
    }

    private func startQueuedReply(_ rig: IdleRig, playing: ReplyDescriptor, waiting: ReplyDescriptor) {
        rig.controller.ingest(firstAudioText(playing))
        rig.controller.ingest(idleAudio(playing, sequence: 0, final: false, byte: 1))
        rig.advance(by: .seconds(1))
        rig.controller.ingest(firstAudioText(waiting))
        rig.advance(by: .seconds(2))
    }

    private func finishLongStream(_ rig: IdleRig, playing: ReplyDescriptor) {
        for sequence in 1...20 { // t=3 through t=60, one frame every three seconds.
            rig.controller.ingest(idleAudio(playing, sequence: sequence, final: sequence == 20, byte: 1))
            #expect(rig.abandoned == 0)
            #expect(rig.liveDeadlineCount == (sequence == 20 ? 1 : 2))
            if sequence < 20 { rig.advance(by: .seconds(3)) }
        }
        rig.player.completeReply()
    }

    private func activityFrame(_ kind: String, reply: ReplyDescriptor, duplicate: HostReplyEvent) -> HostReplyEvent {
        if kind == "duplicate" { return duplicate }
        var event = idleAudio(reply, sequence: 1, final: true, byte: 1)
        if kind == "descriptorless", case .audio(var audio) = event.frame.payload {
            audio.reply = nil
            event.frame.payload = .audio(audio)
        } else if kind == "refused", case .audio(var audio) = event.frame.payload {
            audio.codec = .opus
            audio.reply = idleReply()
            event.frame.payload = .audio(audio)
        }
        return event
    }
}
