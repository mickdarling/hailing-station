import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825: every known status has a deliberate route; a future or absent status fails safe to the banner.
@MainActor
@Suite struct AnnouncerStatusTests {
    @Test func knownStatusesUseExplicitRoutesAndUnknownOrStatuslessLossesFallBack() async {
        let statuses: [String?] = [nil, "Future player failure", ReplyPlaybackController.abandonedStatus,
                                  ReplyPlaybackController.audioFormatNotPlayable,
                                  ReplyPlaybackController.audioCouldNotBeDecoded,
                                  ReplyPlaybackController.playbackFailed]
        for status in statuses {
            let rig = IdleRig(), renderer = CountingRenderer(), fallback = FirstAudioFallbacks()
            let announcer = Announcer(playback: rig.controller, renderer: renderer) { fallback.record($0, $1) }
            announcer.announceAudioProblem(status)
            await settleFirstAudio()
            switch status {
            case ReplyPlaybackController.abandonedStatus:
                #expect(renderer.rendered == [.replyAudioLost])
                #expect(fallback.announcements.isEmpty)
            case ReplyPlaybackController.audioFormatNotPlayable, ReplyPlaybackController.audioCouldNotBeDecoded:
                #expect(renderer.rendered == [.replyAudioFailed])
                #expect(fallback.announcements.isEmpty)
            default:
                #expect(renderer.rendered.isEmpty)
                #expect(rig.player.scheduled.isEmpty)
                #expect(fallback.announcements == [.replyAudioFailed])
                #expect(fallback.reasons == [.playerFailed])
            }
        }
    }
}
