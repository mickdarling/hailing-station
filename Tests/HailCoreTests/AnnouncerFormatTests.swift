import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #838 review: a reply in a format the app can't play yet never reached the player, which still works, so its cue
/// is spoken rather than going straight to the banner; a real playback failure still falls back.
@MainActor
@Suite struct AnnouncerFormatTests {
    @Test func anUnplayableFormatIsSpokenNotJustShown() async {
        let controller = ReplyPlaybackController(player: SilentPlayer())
        let renderer = RecordingRenderer()
        var fallbacks: [Announcement] = []
        let announcer = Announcer(playback: controller, renderer: renderer) { announcement, _ in
            fallbacks.append(announcement)
        }
        announcer.watchReplyAudio { true }
        let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
        let opus = AudioPayload(codec: .opus, sampleRate: 48_000, channels: 1, sequence: 0,
                                streamID: reply.audioStreamID, isFinal: true, bytes: Data([1, 2]), reply: reply)
        controller.ingest(HostReplyEvent(endpointID: "main", frame: Frame(
            timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(opus))))
        for _ in 0..<10 { await Task.yield() }
        #expect(renderer.rendered == [.replyAudioFailed], "spoken through the player, which was never tried")
        #expect(fallbacks.isEmpty)
        withExtendedLifetime(announcer) {}
    }
}

@MainActor
private final class RecordingRenderer: AnnouncementRendering {
    var rendered: [Announcement] = []
    func audio(for announcement: Announcement) async throws -> [AudioPayload] {
        rendered.append(announcement)
        return [AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: UUID(),
                             isFinal: true, bytes: Data([1, 0]))]
    }
}

@MainActor
private final class SilentPlayer: ReplyAudioPlaying {
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}
