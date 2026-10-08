import Foundation
import HailCore
import HailProtocol
import Testing

/// A new reply supersedes a paused one (#321): it plays at once, and the paused reply never resumes.
@MainActor
@Suite struct ReplyPlaybackSupersedeTests {
    @Test func aNewReplyWhilePausedPlaysAndTheOldOneIsSkipped() {
        let player = SupersedeRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        let old = reply(), new = reply()
        controller.ingest(audio(old, sequence: 0, final: false, byte: 10))
        controller.togglePause()
        #expect(controller.isPaused)

        controller.ingest(audio(new, sequence: 0, final: true, byte: 20))
        #expect(!controller.isPaused)
        #expect(player.cancelCount == 1)
        #expect(player.scheduled.map(\.bytes.first) == [10, 20])
        #expect(controller.status == "Playing")
        // The rest of the paused reply is ignored.
        controller.ingest(audio(old, sequence: 1, final: true, byte: 11))
        #expect(player.scheduled.map(\.bytes.first) == [10, 20])
    }

    @Test func aPausedReplyAndOlderQueuedRepliesAreAllSkipped() {
        let player = SupersedeRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audio(reply(), sequence: 0, final: false, byte: 10))
        controller.ingest(audio(reply(), sequence: 0, final: true, byte: 30))
        controller.togglePause()
        controller.ingest(audio(reply(), sequence: 0, final: true, byte: 40))
        #expect(player.scheduled.map(\.bytes.first) == [10, 40])
    }

    @Test func moreSegmentsOfTheSameReplyDoNotSkipIt() {
        let player = SupersedeRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        let only = reply()
        controller.ingest(audio(only, sequence: 0, final: false, byte: 10))
        controller.togglePause()
        controller.ingest(audio(only, sequence: 1, final: true, byte: 11))
        #expect(controller.isPaused)
        #expect(player.cancelCount == 0)
        controller.togglePause()
        #expect(player.scheduled.map(\.bytes.first) == [10, 11])
    }

    @Test func withoutAPauseRepliesStillPlayInOrder() {
        let player = SupersedeRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audio(reply(), sequence: 0, final: false, byte: 10))
        controller.ingest(audio(reply(), sequence: 0, final: true, byte: 20))
        #expect(player.cancelCount == 0)
        #expect(player.scheduled.map(\.bytes.first) == [10])
    }

    @Test func aNewReplyWhileListeningWaitsForListeningToEnd() {
        let player = SupersedeRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audio(reply(), sequence: 0, final: false, byte: 10))
        controller.togglePause()
        controller.beginCaptureSuppression()
        controller.ingest(audio(reply(), sequence: 0, final: true, byte: 20))
        #expect(player.scheduled.map(\.bytes.first) == [10])
        controller.endCaptureSuppression()
        #expect(player.scheduled.map(\.bytes.first) == [10, 20])
    }
}

private final class SupersedeRecordingPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var cancelCount = 0

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
    }
    func cancel() { cancelCount += 1 }
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}

private func reply() -> ReplyDescriptor {
    ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
}

private func audio(_ reply: ReplyDescriptor, sequence: Int, final: Bool, byte: UInt8) -> HostReplyEvent {
    let payload = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
        streamID: reply.audioStreamID, isFinal: final, bytes: Data([byte, 0]), reply: reply
    )
    let frame = Frame(
        timestamp: Int64(sequence), target: reply.targetID, source: reply.hostID, payload: .audio(payload)
    )
    return HostReplyEvent(endpointID: "main", frame: frame)
}
