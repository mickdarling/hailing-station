import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// Failures of a queued stream must respect Replay ownership of the shared player (#825, #1259).
@MainActor
@Suite struct ReplyPlaybackSharedCancelTests {
    @Test func malformedQueuedTailLeavesReplayPlaying() throws {
        try checkSharedCancellation(malformed: true)
    }

    @Test func schedulingFailureAfterReplayCancelsOnlyFailedReply() throws {
        try checkSharedCancellation(malformed: false)
    }

    private func checkSharedCancellation(malformed: Bool) throws {
        let player = SharedCancelPlayer()
        let controller = ReplyPlaybackController(player: player)
        let replayed = formatReply()
        let failed = formatReply()
        controller.ingest(formatAudioEvent(replayed, codec: .pcm16, byteCount: 48_000))
        let replayPresentation = try #require(controller.latest)
        player.completeNextReply()
        controller.replayLatest()
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 2, isFinal: false))
        let failedPresentation = try #require(controller.latest)
        #expect(controller.playbackOrder.map(\.replyID) == [replayed.id])
        #expect(controller.isReplyAudioOutputBusy)

        if !malformed { player.failingSequence = 1 }
        controller.ingest(formatAudioEvent(
            failed, codec: .pcm16, byteCount: malformed ? 1 : 2, sequence: malformed ? 2 : 1
        ))
        #expect(player.cancelCount == 0 && controller.activeKey?.replyID == replayed.id)
        #expect(controller.status(for: replayPresentation) == "Replaying")
        #expect(player.scheduled.compactMap { $0.reply?.id } == [replayed.id])
        player.completeNextReply()
        #expect(player.cancelCount == (malformed ? 0 : 1))
        #expect(controller.activeKey == nil && !controller.isReplyAudioOutputBusy)
        #expect(controller.playbackOrder.isEmpty && controller.queue.isEmpty && controller.streams.isEmpty)
        #expect(controller.status(for: replayPresentation) == "Played")
        let failureStatus = malformed ? "Audio couldn't be decoded" : "Playback failed"
        #expect(controller.status(for: failedPresentation) == failureStatus)
        checkFIFORecovery(controller, player: player)
        #expect(controller.status(for: failedPresentation) == failureStatus)
    }

    private func checkFIFORecovery(_ controller: ReplyPlaybackController, player: SharedCancelPlayer) {
        let next = formatReply()
        let last = formatReply()
        controller.ingest(formatAudioEvent(next, codec: .pcm16, byteCount: 2))
        controller.ingest(formatAudioEvent(last, codec: .pcm16, byteCount: 2))
        #expect(player.scheduled.last?.reply?.id == next.id)
        player.completeNextReply()
        #expect(player.scheduled.last?.reply?.id == last.id)
        player.completeNextReply()
        #expect(controller.activeKey == nil)
        #expect(controller.playbackOrder.isEmpty && controller.queue.isEmpty && controller.streams.isEmpty)
        #expect(!controller.isReplyAudioOutputBusy)
        #expect(controller.statusForControls == "Played")
    }
}

@MainActor
private final class SharedCancelPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var completions: [@MainActor @Sendable () -> Void] = []
    var failingSequence: Int?
    var cancelCount = 0

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        if payload.sequence == failingSequence { throw ReplyAudioPlayerError.invalidBuffer }
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
    func completeNextReply() { completions.removeFirst()() }
}
