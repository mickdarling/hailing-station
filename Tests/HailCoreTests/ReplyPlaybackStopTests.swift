import Foundation
import HailCore
import HailProtocol
import Testing

/// The host's `stop_playback` (#309) silences the player and drops that host's queued replies.
@MainActor
@Suite struct ReplyPlaybackStopTests {
    @Test func stopCancelsThePlayerAndDropsTheHostsReplies() {
        let player = StopRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        let playing = reply(), queued = reply()
        controller.ingest(audio(playing, sequence: 0, final: false, byte: 10))
        controller.ingest(audio(queued, sequence: 0, final: true, byte: 20))
        #expect(player.scheduled.map(\.bytes.first) == [10])

        controller.ingest(stop())
        #expect(player.cancelCount == 1)
        #expect(controller.status == "Stopped")
        #expect(!controller.isReplyAudioOutputBusy)
        // The rest of the stopped reply never starts it again, and the queued reply never plays.
        controller.ingest(audio(playing, sequence: 1, final: true, byte: 11))
        #expect(player.scheduled.map(\.bytes.first) == [10])
    }

    @Test func aReplyAfterTheStopPlaysNormally() {
        let player = StopRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audio(reply(), sequence: 0, final: false, byte: 10))
        controller.ingest(stop())
        controller.ingest(audio(reply(), sequence: 0, final: true, byte: 30))
        #expect(player.scheduled.map(\.bytes.first) == [10, 30])
        #expect(controller.status == "Playing")
    }

    @Test func anotherHostsQueuedReplyPlaysAfterTheStop() {
        let player = StopRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audio(reply(), sequence: 0, final: false, byte: 10))
        controller.ingest(audio(reply(), sequence: 0, final: true, byte: 40, endpoint: "other"))
        controller.ingest(stop())
        #expect(player.scheduled.map(\.bytes.first) == [10, 40])
    }

    @Test func aStopWithNothingPlayingChangesNothing() {
        let player = StopRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(stop())
        #expect(player.cancelCount == 0)
        #expect(controller.status == "No replies yet")
    }

    @Test func aRepeatedStopFrameIsIgnored() {
        let player = StopRecordingPlayer()
        let controller = ReplyPlaybackController(player: player)
        let frame = stop()
        controller.ingest(audio(reply(), sequence: 0, final: false, byte: 10))
        controller.ingest(frame)
        controller.ingest(audio(reply(), sequence: 0, final: false, byte: 50))
        controller.ingest(frame)
        #expect(player.cancelCount == 1)
        #expect(player.scheduled.map(\.bytes.first) == [10, 50])
    }
}

private final class StopRecordingPlayer: ReplyAudioPlaying {
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

private func audio(_ reply: ReplyDescriptor, sequence: Int, final: Bool, byte: UInt8,
                   endpoint: HostEndpoint.Identifier = "main") -> HostReplyEvent {
    let payload = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
        streamID: reply.audioStreamID, isFinal: final, bytes: Data([byte, 0]), reply: reply
    )
    let frame = Frame(
        timestamp: Int64(sequence), target: reply.targetID, source: reply.hostID, payload: .audio(payload)
    )
    return HostReplyEvent(endpointID: endpoint, frame: frame)
}

private func stop(endpoint: HostEndpoint.Identifier = "main") -> HostReplyEvent {
    HostReplyEvent(endpointID: endpoint, frame: Frame(timestamp: 1, source: "host", payload: .control(.stopPlayback)))
}
