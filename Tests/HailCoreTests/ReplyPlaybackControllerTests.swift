import Foundation
import HailCore
import HailProtocol
import Testing

@MainActor
@Suite struct ReplyPlaybackControllerTests {
    @Test func gapsAndOverlappingRepliesStayInTheirOwnFIFOStreams() throws {
        let player = FakeReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let first = descriptor(id: UUID(), stream: UUID())
        let second = descriptor(id: UUID(), stream: UUID())

        controller.ingest(event(first, sequence: 0, final: false, byte: 10))
        controller.ingest(event(second, sequence: 0, final: true, byte: 20))
        controller.ingest(event(first, sequence: 2, final: true, byte: 12))
        #expect(player.scheduled.map(\.sequence) == [0])
        controller.ingest(event(first, sequence: 1, final: false, byte: 11))

        #expect(player.scheduled.map(\.bytes.first) == [10, 11, 12, 20])
    }

    @Test func transcriptControlsAndReplayAreImmediate() {
        let player = FakeReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let reply = descriptor(id: UUID(), stream: UUID())
        let text = Frame(
            timestamp: 1, target: reply.targetID, source: reply.hostID,
            payload: .text(TextPayload(text: "All checks passed", reply: reply))
        )
        controller.ingest(HostReplyEvent(endpointID: "main", frame: text))
        controller.ingest(event(reply, sequence: 0, final: true, byte: 1))
        controller.togglePause()
        controller.toggleMute()
        controller.replayLatest()

        #expect(controller.latest?.transcript == "All checks passed")
        #expect(player.pauseCount == 1 && player.muted)
        #expect(player.replaced.count == 1)
    }
}

@MainActor
private final class FakeReplyPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var replaced: [AudioPayload] = []
    var pauseCount = 0
    var muted = false

    func schedule(_ payload: AudioPayload) { scheduled.append(payload) }
    func pause() { pauseCount += 1 }
    func resume() {}
    func setMuted(_ muted: Bool) { self.muted = muted }
    func replaceQueue(with payloads: [AudioPayload]) { replaced = payloads }
}

private func descriptor(id: UUID, stream: UUID) -> ReplyDescriptor {
    ReplyDescriptor(id: id, hostID: "main-mac", targetID: "tmux:codex", audioStreamID: stream)
}

private func event(_ reply: ReplyDescriptor, sequence: Int, final: Bool, byte: UInt8) -> HostReplyEvent {
    let audio = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
        streamID: reply.audioStreamID, isFinal: final, bytes: Data([byte, 0]), reply: reply
    )
    let frame = Frame(
        timestamp: Int64(sequence), target: reply.targetID, source: reply.hostID, payload: .audio(audio)
    )
    return HostReplyEvent(endpointID: "main", frame: frame)
}
