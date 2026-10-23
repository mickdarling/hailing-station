import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// Malformed PCM fails its stream before the player is tried, so a valid local cue can still play (#825).
@MainActor
@Suite struct ReplyPlaybackMalformedTests {
    @Test(arguments: [0, 1]) func malformedPCMIsNeverScheduled(byteCount: Int) throws {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let reply = formatReply()
        let event = formatAudioEvent(reply, codec: .pcm16, byteCount: byteCount)
        // Both payloads are wire-valid: decode leaves PCM validation to playback.
        let frame = try JSONDecoder().decode(Frame.self, from: JSONEncoder().encode(event.frame))
        controller.ingest(HostReplyEvent(endpointID: event.endpointID, frame: frame))
        let presentation = try #require(controller.latest)
        #expect(controller.status(for: presentation) == "Audio couldn't be decoded")
        #expect(controller.audioProblem(replyID: presentation.id) == ReplyPlaybackController.audioCouldNotPlay)
        #expect(controller.lastPlaybackError == nil)
        #expect(player.scheduled.isEmpty)
        controller.ingest(formatAudioEvent(reply, codec: .pcm16, byteCount: 2))
        controller.ingest(formatAudioEvent(reply, codec: .pcm16, byteCount: 2, sequence: 1))
        #expect(player.scheduled.isEmpty, "later frames cannot revive a refused stream")
        #expect(controller.status(for: presentation) == "Audio couldn't be decoded")
    }

    @Test func malformedTailCancelsTheStreamAndAdvancesFIFO() throws {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let failed = formatReply()
        let queued = formatReply()
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 2, isFinal: false))
        let presentation = try #require(controller.latest)
        controller.ingest(formatAudioEvent(queued, codec: .pcm16, byteCount: 2))
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 1, sequence: 2))
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 2, sequence: 1))
        #expect(player.cancelCount == 1)
        #expect(player.scheduled.compactMap { $0.reply?.id } == [failed.id, queued.id])
        #expect(controller.status(for: presentation) == "Audio couldn't be decoded")
        player.completeNextReply()
        #expect(controller.statusForControls == "Played")
        #expect(controller.status(for: presentation) == "Audio couldn't be decoded")
    }

    @Test func malformedQueuedReplyLeavesTheAudibleReplyAndItsCompletionIntact() throws {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let playing = formatReply()
        let refused = formatReply()
        controller.ingest(formatAudioEvent(playing, codec: .pcm16, byteCount: 2))
        let presentation = try #require(controller.latest)
        controller.ingest(formatAudioEvent(refused, codec: .pcm16, byteCount: 0, sequence: 1))
        let refusedPresentation = try #require(controller.latest)
        #expect(controller.status(for: refusedPresentation) == "Audio couldn't be decoded")
        #expect(controller.statusForControls == "Playing")
        #expect(player.cancelCount == 0)
        controller.ingest(formatAudioEvent(refused, codec: .pcm16, byteCount: 2))
        player.completeNextReply()
        #expect(player.scheduled.compactMap { $0.reply?.id } == [playing.id])
        #expect(controller.status(for: presentation) == "Played")
        #expect(controller.status(for: refusedPresentation) == "Audio couldn't be decoded")
        #expect(!controller.isReplyAudioOutputBusy)
    }
}

func formatReply() -> ReplyDescriptor {
    ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
}

func formatAudioEvent(
    _ reply: ReplyDescriptor, codec: AudioCodec, byteCount: Int,
    sequence: Int = 0, byte: UInt8 = 1, isFinal: Bool = true
) -> HostReplyEvent {
    let audio = AudioPayload(
        codec: codec, sampleRate: 24_000, channels: 1, sequence: sequence,
        streamID: reply.audioStreamID, isFinal: isFinal,
        bytes: Data(repeating: byte, count: byteCount), reply: reply
    )
    let frame = Frame(
        timestamp: Int64(sequence), target: reply.targetID, source: reply.hostID, payload: .audio(audio)
    )
    return HostReplyEvent(endpointID: "main", frame: frame)
}
