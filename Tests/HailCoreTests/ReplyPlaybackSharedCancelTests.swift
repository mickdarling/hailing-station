import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// A shared-player failure must retire the replay ahead of the failed stream too (#825).
@MainActor
@Suite struct ReplyPlaybackSharedCancelTests {
    @Test func malformedTailDuringReplayReconcilesSharedCancellation() throws {
        try checkSharedCancellation(malformed: true)
    }

    @Test func scheduleThrowDuringReplayReconcilesSharedCancellation() throws {
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
        #expect(controller.playbackOrder.count == 2)
        #expect(controller.isReplyAudioOutputBusy)

        if !malformed { player.failingSequence = 1 }
        controller.ingest(formatAudioEvent(
            failed, codec: .pcm16, byteCount: malformed ? 1 : 2, sequence: malformed ? 2 : 1
        ))
        #expect(player.cancelCount == 1)
        #expect(controller.activeKey == nil)
        #expect(controller.playbackOrder.isEmpty && controller.queue.isEmpty && controller.streams.isEmpty)
        #expect(!controller.isPaused && !controller.isReplyAudioOutputBusy)
        #expect(controller.status != "Playing" && controller.statusForControls != "Playing")
        #expect(controller.status(for: replayPresentation) == "Replay failed")
        let failureStatus = malformed ? "Audio couldn't be decoded" : "Playback failed"
        #expect(controller.status(for: failedPresentation) == failureStatus)
        #expect(controller.idleWatch.aheadUntil <= controller.idleNow())
        player.completeNextReply() // The cancelled replay still delivers its stale completion (#825).
        #expect(controller.activeKey == nil && !controller.isReplyAudioOutputBusy)
        #expect(controller.status(for: replayPresentation) == "Replay failed")
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
