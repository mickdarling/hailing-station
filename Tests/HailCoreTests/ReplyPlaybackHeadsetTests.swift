import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// The headset's pause press during a reply (#269 interim) stops every reply and mutes later ones.
@MainActor
@Suite struct ReplyPlaybackHeadsetTests {
    @Test func thePressStopsEveryHostsRepliesAndMutes() {
        let player = IdlePlayer()
        let controller = ReplyPlaybackController(player: player)
        let playing = idleReply()
        controller.ingest(idleAudio(playing, sequence: 0, final: false, byte: 10))
        controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 20))
        controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 30, endpoint: "other"))

        #expect(controller.stopAndMuteFromHeadset())
        #expect(player.cancelCount == 1)
        #expect(controller.isMuted)
        #expect(controller.status == "Muted")
        #expect(!controller.isReplyAudioOutputBusy)
        // Neither the rest of the stopped reply nor either queued reply plays.
        controller.ingest(idleAudio(playing, sequence: 1, final: true, byte: 11))
        #expect(player.scheduled.map(\.bytes.first) == [10])
    }

    @Test func aLaterReplyPlaysMuted() {
        let player = IdlePlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(idleAudio(idleReply(), sequence: 0, final: false, byte: 10))
        controller.stopAndMuteFromHeadset()
        controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 40))
        #expect(player.scheduled.map(\.bytes.first) == [10, 40])
        #expect(controller.isMuted)
    }

    @Test func aPressWithNoReplyChangesNothing() {
        let player = IdlePlayer()
        let controller = ReplyPlaybackController(player: player)
        #expect(!controller.stopAndMuteFromHeadset())
        #expect(player.cancelCount == 0)
        #expect(!controller.isMuted)
        #expect(controller.status == "No replies yet")
    }

    @Test func aPressWhileAVoiceMuteWaitsMutesAtOnce() {
        let player = IdlePlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 10)) // "Muted."
        controller.ingest(HostReplyEvent(endpointID: "main", frame: Frame(
            timestamp: 1, source: "host", payload: .control(.setReplyMute(muted: true))
        )))
        #expect(!controller.isMuted)
        controller.stopAndMuteFromHeadset()
        #expect(controller.isMuted)
    }

    @Test func aPressWhilePausedStopsAndMutes() {
        let player = IdlePlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(idleAudio(idleReply(), sequence: 0, final: false, byte: 10))
        controller.togglePause()
        #expect(controller.stopAndMuteFromHeadset())
        #expect(controller.isMuted && !controller.isPaused)
        #expect(controller.status == "Muted")
    }

    @Test func aPressWhileListeningStopsAndMutesAndKeepsTheListeningStatus() {
        let player = IdlePlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(idleAudio(idleReply(), sequence: 0, final: false, byte: 10))
        controller.beginCaptureSuppression()
        #expect(controller.stopAndMuteFromHeadset())
        #expect(controller.isMuted && player.cancelCount == 1)
        #expect(controller.statusForControls == "Paused while listening")
        controller.endCaptureSuppression()
        #expect(controller.status == "Muted")
    }
}
