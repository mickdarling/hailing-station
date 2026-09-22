import Foundation
import HailCore
import HailProtocol
import Testing
@MainActor
@Suite struct ReplyPlaybackFormatTests {
    @Test func unsupportedAudioStillPublishesItsReplyAndStatus() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let reply = makeReply()

        controller.ingest(audioEvent(reply, codec: .opus, byteCount: 1))

        #expect(controller.latest?.id.contains(reply.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Audio format is not yet playable")
        #expect(player.scheduled.isEmpty)
    }

    @Test func firstTextOnlyReplyHasAReplySpecificStatus() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let reply = makeReply()
        let frame = Frame(
            timestamp: 0, target: reply.targetID, source: reply.hostID,
            payload: .text(TextPayload(text: "Ready", reply: reply))
        )
        controller.ingest(HostReplyEvent(endpointID: "main", frame: frame))
        #expect(controller.presentationForControls?.id.contains(reply.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Received")
    }

    @Test func unsupportedStatusWaitsForItsReplyToBecomeCurrent() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let playing = makeReply()
        controller.ingest(audioEvent(playing, codec: .pcm16, byteCount: 2))
        let unsupported = makeReply()
        controller.ingest(audioEvent(unsupported, codec: .opus, byteCount: 1))
        let text = Frame(
            timestamp: 1, target: unsupported.targetID, source: unsupported.hostID,
            payload: .text(TextPayload(text: "Transcript", reply: unsupported))
        )
        controller.ingest(HostReplyEvent(endpointID: "main", frame: text))
        #expect(controller.presentationForControls?.id.contains(playing.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Playing")
        player.completeNextReply()
        #expect(controller.presentationForControls?.id.contains(unsupported.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Audio format is not yet playable")
    }

    @Test func incompleteQueuedReplyIsShownAsWaitingAfterPlayback() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let first = makeReply()
        let waiting = makeReply()
        controller.ingest(audioEvent(first, codec: .pcm16, byteCount: 2))
        controller.ingest(audioEvent(waiting, codec: .pcm16, byteCount: 2, sequence: 1))

        player.completeNextReply()

        #expect(controller.presentationForControls?.id.contains(waiting.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Waiting for audio")
    }

    @Test func queuedConflictAppearsOnlyWithItsReply() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let first = makeReply()
        let conflicted = makeReply()
        controller.ingest(audioEvent(first, codec: .pcm16, byteCount: 2))
        controller.ingest(audioEvent(conflicted, codec: .pcm16, byteCount: 2, sequence: 1))
        controller.ingest(audioEvent(conflicted, codec: .pcm16, byteCount: 2, sequence: 1, byte: 2))

        #expect(controller.presentationForControls?.id.contains(first.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Playing")
        player.completeNextReply()
        #expect(controller.presentationForControls?.id.contains(conflicted.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Conflicting audio segment refused")
    }

    @Test func failedInitialScheduleDoesNotRemainAudibleOrBlockReplay() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audioEvent(makeReply(), codec: .pcm16, byteCount: 2))
        player.completeNextReply()
        let failed = makeReply()
        player.shouldFailSchedule = true

        controller.ingest(audioEvent(failed, codec: .pcm16, byteCount: 2))

        #expect(controller.presentationForControls?.id.contains(failed.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Playback failed")
        controller.replayLatest()
        #expect(controller.status == "Replaying")
        #expect(player.replaceCount == 1)
    }

    @Test func failedLaterSegmentClearsStreamAndAdvancesFIFO() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let failed = makeReply()
        let queued = makeReply()
        controller.ingest(audioEvent(
            failed, codec: .pcm16, byteCount: 2, sequence: 0, isFinal: false
        ))
        controller.ingest(audioEvent(queued, codec: .pcm16, byteCount: 2))
        player.failingSequence = 1

        controller.ingest(audioEvent(failed, codec: .pcm16, byteCount: 1, sequence: 1))

        #expect(player.cancelCount == 1)
        #expect(player.scheduled.compactMap { $0.reply?.id } == [failed.id, queued.id])
        #expect(controller.presentationForControls?.id.contains(queued.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Playing")
        player.completeNextReply()
        #expect(controller.statusForControls == "Played")
    }

    @Test func replayFailureRemainsVisibleAfterQueueCleanup() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audioEvent(makeReply(), codec: .pcm16, byteCount: 2))
        player.completeNextReply()
        player.shouldFailReplay = true

        controller.replayLatest()
        #expect(controller.statusForControls == "Replay failed")
        player.shouldFailReplay = false
        controller.replayLatest()
        #expect(controller.statusForControls == "Replaying")
    }

    @Test func replayFailureDoesNotOverwriteTheNextQueuedReply() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let first = makeReply()
        let second = makeReply()
        controller.ingest(audioEvent(first, codec: .pcm16, byteCount: 2))
        controller.ingest(audioEvent(second, codec: .pcm16, byteCount: 2))
        player.shouldFailReplay = true

        controller.replayLatest()

        #expect(controller.presentationForControls?.id.contains(second.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Playing")
        #expect(player.scheduled.compactMap { $0.reply?.id } == [first.id, second.id])
    }
}

private func makeReply() -> ReplyDescriptor {
    ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
}

private func audioEvent(
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

@MainActor
private final class FormatTestPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var completions: [@MainActor @Sendable () -> Void] = []
    var shouldFailSchedule = false
    var failingSequence: Int?
    var shouldFailReplay = false
    var replaceCount = 0
    var cancelCount = 0

    func schedule(
        _ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?
    ) throws {
        if shouldFailSchedule || failingSequence == payload.sequence {
            throw ReplyAudioPlayerError.invalidBuffer
        }
        scheduled.append(payload)
        if let onPlayed { completions.append(onPlayed) }
    }
    func cancel() { cancelCount += 1 }
    func pause() {}
    func resume() {}
    func setMuted(_: Bool) {}
    func replaceQueue(
        with _: [AudioPayload], onPlayed _: (@MainActor @Sendable () -> Void)?
    ) throws {
        if shouldFailReplay { throw ReplyAudioPlayerError.invalidBuffer }
        replaceCount += 1
    }

    func completeNextReply() { completions.removeFirst()() }
}
