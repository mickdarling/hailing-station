import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// A bad reply payload leaves the player available for the station's own valid spoken cue (#825).
@MainActor
@Suite struct AnnouncerDecodeTests {
    @Test(arguments: [0, 1]) func malformedReplyAudioIsSpokenInsteadOfFallingBack(byteCount: Int) async {
        let player = AbandonPlayer()
        let controller = ReplyPlaybackController(player: player)
        let renderer = CountingRenderer()
        let fallback = DecodeFallbackBox()
        let announcer = Announcer(playback: controller, renderer: renderer) { announcement, _ in
            fallback.announcements.append(announcement)
        }
        announcer.watchReplyAudio { true }
        controller.ingest(formatAudioEvent(formatReply(), codec: .pcm16, byteCount: byteCount))
        for _ in 0..<10 { await Task.yield() }
        #expect(renderer.rendered == [.replyAudioFailed])
        #expect(player.scheduled.map(\.bytes) == [Data([1, 0])], "only the valid spoken cue reaches the player")
        #expect(fallback.announcements.isEmpty)
        withExtendedLifetime(announcer) {}
    }

    @Test(arguments: [false, true])
    func malformedTailKeepsItsFailureCuePaused(whileListening: Bool) async {
        let player = AbandonPlayer()
        let controller = ReplyPlaybackController(player: player)
        let renderer = CountingRenderer()
        let fallback = DecodeFallbackBox()
        let announcer = Announcer(playback: controller, renderer: renderer) { announcement, _ in
            fallback.announcements.append(announcement)
        }
        announcer.watchReplyAudio { true }
        let failed = formatReply()
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 2, isFinal: false))
        controller.togglePause()
        if whileListening { controller.beginCaptureSuppression() }
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 1, sequence: 1))
        for _ in 0..<10 { await Task.yield() }
        #expect(renderer.rendered == [.replyAudioFailed])
        #expect(controller.isPaused)
        #expect(player.scheduled.count == 1)
        if whileListening { controller.endCaptureSuppression() }
        #expect(controller.isPaused && player.scheduled.count == 1)
        controller.togglePause()
        #expect(!controller.isPaused)
        #expect(player.scheduled.count == 2 && player.scheduled.last?.reply == nil)
        #expect(player.scheduled.last?.bytes == Data([1, 0]))
        #expect(fallback.announcements.isEmpty)
        withExtendedLifetime(announcer) {}
    }
}

@MainActor
private final class DecodeFallbackBox {
    var announcements: [Announcement] = []
}
