import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// A failed tail retires its audio while the user's pause keeps replies and cues held (#825).
@MainActor
@Suite struct ReplyPlaybackMalformedPauseTests {
    @Test(arguments: [false, true], [0, 1])
    func malformedTailKeepsQueuedReplyPaused(whileListening: Bool, byteCount: Int) throws {
        let rig = IdleRig()
        let controller = rig.controller
        let failed = formatReply(), queued = formatReply()
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 48_000, isFinal: false))
        let failedPresentation = try #require(controller.latest)
        controller.ingest(formatAudioEvent(queued, codec: .pcm16, byteCount: 2, isFinal: false))
        controller.ingest(formatAudioEvent(queued, codec: .pcm16, byteCount: 2, sequence: 1))
        if whileListening { controller.beginCaptureSuppression() }
        controller.togglePause()
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: byteCount, sequence: 1))
        #expect(rig.player.cancelCount == 1)
        #expect(controller.isPaused && !controller.isReplyAudioOutputBusy)
        #expect(controller.activeKey == nil && controller.playbackOrder.isEmpty)
        #expect(controller.queue.count == 1)
        #expect(controller.streams[try #require(controller.queue.first)]?.nextSequence == 0)
        #expect(controller.idleWatch.heldRemaining == .zero && controller.idleWatch.cancel == nil)
        rig.advance(by: .seconds(120))
        if whileListening { controller.endCaptureSuppression() }
        #expect(controller.isPaused && controller.status == "Paused")
        #expect(rig.player.scheduled.compactMap { $0.reply?.id } == [failed.id])
        #expect(rig.abandoned == 0)
        controller.togglePause()
        #expect(!controller.isPaused && controller.isReplyAudioOutputBusy)
        #expect(controller.idleWatch.heldRemaining == nil)
        #expect(rig.player.scheduled.compactMap { $0.reply?.id } == [failed.id, queued.id, queued.id])
        #expect(rig.player.scheduled.suffix(2).map(\.sequence) == [0, 1])
        rig.player.completeReply()
        #expect(controller.statusForControls == "Played")
        #expect(controller.activeKey == nil && controller.queue.isEmpty && controller.streams.isEmpty)
        #expect(controller.status(for: failedPresentation) == ReplyPlaybackController.audioCouldNotBeDecoded)
    }

    @Test func aNewReplyStillSupersedesThePauseAfterFailure() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let failed = formatReply(), queued = formatReply(), newest = formatReply()
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 2, isFinal: false))
        controller.ingest(formatAudioEvent(queued, codec: .pcm16, byteCount: 2))
        controller.togglePause()
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 1, sequence: 1))
        controller.ingest(formatAudioEvent(newest, codec: .pcm16, byteCount: 2))
        #expect(!controller.isPaused)
        #expect(player.scheduled.compactMap { $0.reply?.id } == [failed.id, newest.id])
        player.completeNextReply()
        #expect(controller.statusForControls == "Played")
    }

    @Test func aScheduleThrowWaitsUntilTheUserResumes() {
        let player = FormatTestPlayer()
        let controller = ReplyPlaybackController(player: player)
        let failed = formatReply(), queued = formatReply()
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 2, isFinal: false))
        controller.ingest(formatAudioEvent(queued, codec: .pcm16, byteCount: 2))
        controller.togglePause()
        player.failingSequence = 1
        controller.ingest(formatAudioEvent(failed, codec: .pcm16, byteCount: 2, sequence: 1))
        #expect(controller.isPaused && player.cancelCount == 0)
        #expect(controller.lastPlaybackError == nil && player.scheduled.count == 1)
        controller.togglePause()
        #expect(!controller.isPaused && player.cancelCount == 1)
        #expect(controller.lastPlaybackError != nil)
        #expect(player.scheduled.compactMap { $0.reply?.id } == [failed.id, queued.id])
        player.completeNextReply()
        #expect(controller.statusForControls == "Played")
    }
}
