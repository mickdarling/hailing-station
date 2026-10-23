import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// A refused copy must leave the first segment and any overlapping Replay intact (#825).
@MainActor
@Suite struct ReplyPlaybackDuplicateTests {
    @Test(arguments: [0, 1, 2], [false, true])
    func conflictingCopyPreservesActiveOrQueuedAudio(byteCount: Int, queued: Bool) throws {
        let player = DuplicateTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let ahead = formatReply()
        let reply = formatReply()
        if queued { try ingest(controller, formatAudioEvent(ahead, codec: .pcm16, byteCount: 2)) }
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: 2, isFinal: false))
        let presentation = try #require(controller.latest)
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: byteCount, byte: 2))
        #expect(controller.status(for: presentation) == "Conflicting audio segment refused")
        #expect(controller.audioProblem(replyID: presentation.id) == nil)
        #expect(player.cancelCount == 0)
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: 2, sequence: 1))
        if queued {
            #expect(player.scheduled.compactMap { $0.reply?.id } == [ahead.id])
            try player.completeNextReply()
        }
        let segments = player.scheduled.filter { $0.reply?.id == reply.id }
        #expect(segments.map(\.sequence) == [0, 1])
        #expect(segments.map(\.bytes) == [Data([1, 1]), Data([1, 1])])
        try player.completeNextReply()
        #expect(controller.status(for: presentation) == "Played")
        #expect(controller.audioProblem(replyID: presentation.id) == nil)
        #expect(player.cancelCount == 0)
        expectFinished(controller)
    }

    @Test(arguments: [0, 1]) func malformedCopyDoesNotCancelOverlappingReplay(byteCount: Int) throws {
        let player = DuplicateTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let replayed = formatReply()
        let reply = formatReply()
        try ingest(controller, formatAudioEvent(replayed, codec: .pcm16, byteCount: 2))
        let replayPresentation = try #require(controller.latest)
        try player.completeNextReply()
        controller.replayLatest()
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: 2, isFinal: false))
        let presentation = try #require(controller.latest)
        #expect(controller.playbackOrder.count == 2)
        let generation = controller.playbackGeneration
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: byteCount))
        #expect(player.cancelCount == 0)
        #expect(controller.playbackGeneration == generation)
        #expect(controller.playbackOrder.count == 2)
        #expect(controller.status(for: replayPresentation) == "Playing")
        #expect(controller.status(for: presentation) == "Conflicting audio segment refused")
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: 2, sequence: 1))
        #expect(player.scheduled.compactMap { $0.reply?.id } == [replayed.id, reply.id, reply.id])
        #expect(player.scheduled.suffix(2).map(\.sequence) == [0, 1])
        try player.completeNextReply()
        #expect(controller.status(for: replayPresentation) == "Played")
        #expect(controller.isReplyAudioOutputBusy)
        try player.completeNextReply()
        #expect(controller.status(for: presentation) == "Played")
        #expect(player.cancelCount == 0)
        expectFinished(controller)
    }

    @Test func identicalCopyWithNewFrameIDIsNotScheduledTwice() throws {
        let player = DuplicateTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let reply = formatReply()
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: 2, isFinal: false))
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: 2, isFinal: false))
        #expect(player.scheduled.map(\.sequence) == [0])
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: 2, sequence: 1))
        #expect(player.scheduled.map(\.sequence) == [0, 1])
        try player.completeNextReply()
        #expect(player.cancelCount == 0)
        expectFinished(controller)
    }

    @Test(arguments: [AudioCodec.opus, .pcm16])
    func unsupportedCopyReportsFormatWithoutRetiringAcceptedAudio(codec: AudioCodec) throws {
        let player = DuplicateTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let reply = formatReply()
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: 2, isFinal: false))
        let presentation = try #require(controller.latest)
        var event = formatAudioEvent(reply, codec: codec, byteCount: 0)
        if case .audio(var audio) = event.frame.payload {
            audio.channels = codec == .pcm16 ? 2 : 1
            event.frame.payload = .audio(audio)
        }
        try ingest(controller, event)
        #expect(controller.status(for: presentation) == ReplyPlaybackController.audioFormatNotPlayable)
        #expect(player.cancelCount == 0)
        try ingest(controller, formatAudioEvent(reply, codec: .pcm16, byteCount: 2, sequence: 1))
        #expect(player.scheduled.map(\.sequence) == [0, 1])
        try player.completeNextReply()
        #expect(controller.status(for: presentation) == "Played")
        #expect(player.cancelCount == 0)
        expectFinished(controller)
    }

    private func ingest(_ controller: ReplyPlaybackController, _ event: HostReplyEvent) throws {
        let frame = try JSONDecoder().decode(Frame.self, from: JSONEncoder().encode(event.frame))
        controller.ingest(HostReplyEvent(endpointID: event.endpointID, frame: frame))
    }

    private func expectFinished(_ controller: ReplyPlaybackController) {
        #expect(controller.activeKey == nil && !controller.isReplyAudioOutputBusy)
        #expect(controller.playbackOrder.isEmpty && controller.queue.isEmpty && controller.streams.isEmpty)
        #expect(controller.statusForControls == "Played")
    }
}

@MainActor
private final class DuplicateTestPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var completions: [@MainActor @Sendable () -> Void] = []
    var cancelCount = 0

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        if let onPlayed { completions.append(onPlayed) }
    }
    func replaceQueue(with _: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {
        if let onPlayed { completions.append(onPlayed) }
    }
    func cancel() { cancelCount += 1 }
    func pause() {}
    func resume() {}
    func setMuted(_: Bool) {}
    func completeNextReply() throws {
        let completion = try #require(completions.first)
        completions.removeFirst()
        completion()
    }
}
