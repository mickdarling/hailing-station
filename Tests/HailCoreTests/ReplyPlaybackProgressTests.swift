import Foundation
import HailCore
import HailProtocol
import Testing

@MainActor
@Suite struct ReplyPlaybackProgressTests {
    @Test func perReplyStatusSurvivesAnotherReplyTakingPlayback() throws {
        let player = ProgressReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let first = progressDescriptor()
        let second = progressDescriptor()
        controller.ingest(progressEvent(first, byte: 1))
        controller.ingest(progressEvent(second, byte: 2))

        let firstPresentation = try #require(controller.replies.first)
        let secondPresentation = try #require(controller.replies.last)
        #expect(controller.status(for: firstPresentation) == "Playing")
        #expect(controller.status(for: secondPresentation) == "Queued")

        player.completeNextReply()
        #expect(controller.status(for: firstPresentation) == "Played")
        #expect(controller.status(for: secondPresentation) == "Playing")
    }
}

@MainActor
private final class ProgressReplyPlayer: ReplyAudioPlaying {
    private var completions: [@MainActor @Sendable () -> Void] = []

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        if let onPlayed { completions.append(onPlayed) }
    }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {
        if let onPlayed { completions.append(onPlayed) }
    }
    func completeNextReply() { completions.removeFirst()() }
}

private func progressDescriptor() -> ReplyDescriptor {
    ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
}

private func progressEvent(_ reply: ReplyDescriptor, byte: UInt8) -> HostReplyEvent {
    let audio = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0,
        streamID: reply.audioStreamID, isFinal: true, bytes: Data([byte, 0]), reply: reply
    )
    let frame = Frame(timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(audio))
    return HostReplyEvent(endpointID: "main", frame: frame)
}
