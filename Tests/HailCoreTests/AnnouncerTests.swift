import AVFAudio
import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825 S4b: the station's own spoken cues play only through the reply player, queued behind any reply and never a
/// reply entry or what Replay replays; when muted or unrenderable they fall back, never silently lost (#822); a reply
/// whose audio did not play is announced once.
@MainActor
@Suite struct AnnouncerTests {
    private let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())

    @Test func anAnnouncementPlaysOnlyThroughTheReplyPlayer() async {
        let (player, controller) = rig()
        let announcer = Announcer(playback: controller, renderer: FakeRenderer()) { _, _ in }
        announcer.announce(.replyAudioLost)
        await settle()
        // The player is the only way out, so the capture engine's echo canceller always hears an announcement.
        #expect(player.scheduled.map(\.sequence) == [0, 1])
        #expect(controller.replies.isEmpty, "never a reply entry")
    }

    @Test func itWaitsBehindAReplyAndReplayStillReplaysTheReply() async {
        let (player, controller) = rig()
        controller.ingest(audio(sequence: 0, final: true))
        let announcer = Announcer(playback: controller, renderer: FakeRenderer()) { _, _ in }
        announcer.announce(.replyAudioLost)
        await settle()
        #expect(player.scheduled.count == 1, "queued behind the reply, never interrupting it")
        player.completeNext()
        #expect(player.scheduled.count == 3)
        player.completeNext()
        controller.replayLatest()
        #expect(player.replaced.map(\.bytes) == [Data([7, 0])], "Replay replays the reply, not the announcement")
    }

    @Test func mutedFallsBackInsteadOfPlaying() async {
        let (player, controller) = rig()
        controller.toggleMute()
        var fallbacks: [(Announcement, Announcer.Fallback)] = []
        let announcer = Announcer(playback: controller, renderer: FakeRenderer()) { fallbacks.append(($0, $1)) }
        announcer.announce(.replyAudioLost)
        await settle()
        #expect(player.scheduled.isEmpty)
        #expect(fallbacks.map(\.0) == [.replyAudioLost] && fallbacks.map(\.1) == [.muted])
    }

    @Test func audioThatCannotBeMadeFallsBack() async {
        let (player, controller) = rig()
        var reasons: [Announcer.Fallback] = []
        let announcer = Announcer(playback: controller, renderer: FakeRenderer(fails: true)) { reasons.append($1) }
        announcer.announce(.replyAudioLost)
        await settle()
        #expect(player.scheduled.isEmpty)
        #expect(reasons == [.renderFailed])
    }

    @Test func aReplyThatFailedToPlayFallsBackOnceAndOnlyWhenAllowed() async {
        let controller = ReplyPlaybackController(player: FailingPlayer())
        var fallbacks: [Announcement] = []
        let announcer = Announcer(playback: controller, renderer: FakeRenderer()) { announcement, _ in
            fallbacks.append(announcement)
        }
        var allowed = false
        announcer.watchReplyAudio { allowed }
        controller.ingest(audio(sequence: 0, final: true))
        await settle()
        #expect(fallbacks.isEmpty, "not while VoiceOver's own announcements cover it")
        allowed = true
        controller.ingest(audio(sequence: 0, final: true, reply: ReplyDescriptor(
            id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())))
        await settle()
        await settle()
        #expect(fallbacks == [.replyAudioFailed])
    }

    @Test func synthesizerSamplesBecomeSixteenBit() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let samples = try #require(buffer.floatChannelData?.pointee)
        (samples[0], samples[1], samples[2]) = (1, -2, 0)
        #expect(LocalAnnouncementRenderer.int16Samples(buffer) == [Int16.max, -Int16.max, 0])
    }

    private func rig() -> (AnnouncePlayer, ReplyPlaybackController) {
        let player = AnnouncePlayer()
        return (player, ReplyPlaybackController(player: player))
    }

    private func audio(sequence: Int, final: Bool, reply: ReplyDescriptor? = nil) -> HostReplyEvent {
        let reply = reply ?? self.reply
        let payload = AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
                                   streamID: reply.audioStreamID, isFinal: final, bytes: Data([7, 0]), reply: reply)
        let frame = Frame(timestamp: Int64(sequence), target: reply.targetID, source: reply.hostID,
                          payload: .audio(payload))
        return HostReplyEvent(endpointID: "main", frame: frame)
    }
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private struct FakeRenderer: AnnouncementRendering {
    var fails = false
    func audio(for announcement: Announcement) async throws -> [AudioPayload] {
        if fails { throw ReplyAudioPlayerError.invalidBuffer }
        let stream = UUID()
        return [false, true].enumerated().map { index, final in
            AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: index, streamID: stream,
                         isFinal: final, bytes: Data([1, 0]))
        }
    }
}

@MainActor
private final class AnnouncePlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var replaced: [AudioPayload] = []
    private var completions: [@MainActor @Sendable () -> Void] = []
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        if let onPlayed { completions.append(onPlayed) }
    }
    func completeNext() { completions.removeFirst()() }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {
        replaced = payloads
    }
}

private final class FailingPlayer: ReplyAudioPlaying {
    struct Failure: Error {}
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws { throw Failure() }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}

/// #838 review: the main path. A reply whose stream ended without its final audio is spoken as `replyAudioLost`,
/// through the player, once, however its status changes after.
@MainActor
@Suite struct AnnouncerAbandonTests {
    @Test func aStreamThatEndedEarlyIsSpokenOnce() async {
        let player = AbandonPlayer()
        let controller = ReplyPlaybackController(player: player)
        var now = ContinuousClock.now
        var timers: [(due: ContinuousClock.Instant, fire: @MainActor () -> Void)] = []
        controller.idleNow = { now }
        controller.idleScheduler = { delay, fire in
            timers.append((now.advanced(by: delay), fire))
            return {}
        }
        let renderer = CountingRenderer()
        let announcer = Announcer(playback: controller, renderer: renderer) { _, _ in }
        announcer.watchReplyAudio { true }
        let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
        let payload = AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0,
                                   streamID: reply.audioStreamID, isFinal: false, bytes: Data([1, 0]), reply: reply)
        controller.ingest(HostReplyEvent(endpointID: "main", frame: Frame(
            timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(payload))))
        now = now.advanced(by: .seconds(30))
        for timer in timers where timer.due <= now { timer.fire() }
        for _ in 0..<10 { await Task.yield() }
        #expect(renderer.rendered == [.replyAudioLost])
        #expect(player.scheduled.last?.isFinal == true, "the cue played through the player")
        controller.ingest(HostReplyEvent(endpointID: "main", frame: Frame( // A new status re-runs the watch.
            timestamp: 1, target: reply.targetID, source: reply.hostID, payload: .text(TextPayload(text: "Next")))))
        for _ in 0..<10 { await Task.yield() }
        #expect(renderer.rendered == [.replyAudioLost])
        withExtendedLifetime(announcer) {}
    }
}
@MainActor
private final class CountingRenderer: AnnouncementRendering {
    var rendered: [Announcement] = []
    func audio(for announcement: Announcement) async throws -> [AudioPayload] {
        rendered.append(announcement)
        return [AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: UUID(),
                             isFinal: true, bytes: Data([1, 0]))]
    }
}

@MainActor
private final class AbandonPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) { scheduled.append(payload) }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}
