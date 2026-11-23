import Foundation
@testable import HailCore
import HailProtocol
import Testing

@MainActor
@Suite struct ReplyMuteAfterStopTests {
    @Test func multiHostStopThenMuteSilencesDrainedQueuedReply() {
        let rig = PausedReplyRig()
        let start = ContinuousClock.now
        rig.controller.idleNow = { start }
        let other = queueOtherHostBehindActiveReply(in: rig)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        #expect(rig.player.pending.map(\.payload.reply?.id) == [other.id])

        rig.controller.idleNow = { start + .milliseconds(99) }
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        rig.controller.ingest(idleAudio(other, sequence: 1, final: true, byte: 21, endpoint: "other"))
        #expect(rig.controller.isMuted && rig.player.muted)
        #expect(rig.player.pending.isEmpty && rig.player.played.isEmpty)
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 20])
        #expect(rig.status(other) == "Stopped")
        #expect(rig.controller.presentationForDisplay?.endpointID == "other")
        #expect(rig.controller.presentationForDisplay?.transcript == "Synthetic reply")
    }

    @Test func muteAfterControlWindowKeepsDeferral() async throws {
        let rig = PausedReplyRig()
        let start = ContinuousClock.now
        rig.controller.idleNow = { start }
        let other = queueOtherHostBehindActiveReply(in: rig)
        rig.controller.ingest(firstAudioControl(.stopPlayback))

        // Each fixture frame lasts 1.25 s. The window expires even before its played notification.
        rig.controller.idleNow = { start + .milliseconds(101) }
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        #expect(!rig.controller.isMuted && !rig.player.muted)
        try await rig.player.playNext()
        rig.controller.ingest(idleAudio(other, sequence: 1, final: true, byte: 21, endpoint: "other"))
        #expect(rig.player.mutedWhenScheduled.last == false)
        try await rig.player.playNext()
        #expect(rig.controller.isMuted && rig.player.muted)
    }

    @Test func firstFramePlayedInsideWindowKeepsDeferral() async throws {
        let rig = PausedReplyRig()
        let start = ContinuousClock.now
        rig.controller.idleNow = { start }
        let other = queueOtherHostBehindActiveReply(in: rig)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        try await rig.player.playNext()
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        #expect(!rig.controller.isMuted && !rig.player.muted)
        rig.controller.ingest(idleAudio(other, sequence: 1, final: true, byte: 21, endpoint: "other"))
        try await rig.player.playNext()
        #expect(rig.controller.isMuted && rig.player.muted)
    }

    @Test func singleHostStopThenMuteUnchanged() async throws {
        let rig = PausedReplyRig()
        let start = ContinuousClock.now
        rig.controller.idleNow = { start }
        rig.ingest(idleReply(), byte: 10)
        rig.ingest(idleReply(), byte: 20)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        // A confirmation arriving after the stop still gets its full turn.
        rig.ingest(idleReply(), byte: 30)
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        #expect(!rig.player.muted)
        try await rig.player.playNext()
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 30])
        #expect(rig.player.played.map(\.bytes.first) == [30])
        #expect(rig.controller.isMuted && rig.player.muted)
    }

    @Test func explicitStopUnchanged() async throws {
        let rig = PausedReplyRig()
        let other = queueOtherHostBehindActiveReply(in: rig)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        rig.controller.ingest(idleAudio(other, sequence: 1, final: true, byte: 21, endpoint: "other"))
        try await rig.player.playNext()
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [20, 21])
        #expect(rig.status(other) == "Played")
        #expect(rig.player.cancelCount == 1)
        #expect(!rig.controller.isMuted && !rig.player.muted)
    }

    @Test func muteBeforeFrameZeroRetiresWaitingReplyAcrossUnmute() {
        let rig = PausedReplyRig()
        let start = ContinuousClock.now
        rig.controller.idleNow = { start }
        let other = queueOtherHostBehindActiveReply(in: rig, sequence: 1)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        #expect(rig.player.pending.isEmpty)

        rig.controller.idleNow = { start + .milliseconds(10) }
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        #expect(rig.controller.isMuted && rig.player.muted)
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: false)))
        rig.controller.idleNow = { start + .milliseconds(20) }
        rig.controller.ingest(idleAudio(other, sequence: 0, final: false, byte: 19, endpoint: "other"))
        #expect(!rig.player.muted && rig.player.pending.isEmpty)
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        #expect(rig.status(other) == "Stopped")
    }

    @Test func muteAfterLateFrameZeroCancelsScheduledAudio() {
        let rig = PausedReplyRig()
        let start = ContinuousClock.now
        rig.controller.idleNow = { start }
        let other = queueOtherHostBehindActiveReply(in: rig, sequence: 1)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        rig.controller.idleNow = { start + .milliseconds(10) }
        rig.controller.ingest(idleAudio(other, sequence: 0, final: false, byte: 19, endpoint: "other"))
        #expect(rig.player.pending.map(\.payload.sequence) == [0, 1])

        rig.controller.idleNow = { start + .milliseconds(20) }
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        #expect(rig.controller.isMuted && rig.player.muted)
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: false)))
        rig.controller.ingest(idleAudio(other, sequence: 2, final: true, byte: 21, endpoint: "other"))
        #expect(rig.player.pending.isEmpty && rig.player.played.isEmpty)
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 19, 20])
        #expect(rig.status(other) == "Stopped")
    }

    @Test func lateFrameZeroDoesNotExtendStopDeadline() {
        let rig = PausedReplyRig()
        let start = ContinuousClock.now
        rig.controller.idleNow = { start }
        let other = queueOtherHostBehindActiveReply(in: rig, sequence: 1)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        rig.controller.idleNow = { start + .milliseconds(90) }
        rig.controller.ingest(idleAudio(other, sequence: 0, final: false, byte: 19, endpoint: "other"))
        rig.controller.idleNow = { start + .milliseconds(100) }
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        #expect(!rig.player.muted && !rig.controller.isMuted)
        #expect(rig.player.pending.map(\.payload.sequence) == [0, 1])
    }

    @Test func muteAfterFlushedFirstFrameStillSilencesPromotedReply() throws {
        let rig = PausedReplyRig()
        let start = ContinuousClock.now
        rig.controller.idleNow = { start }
        let other = queueOtherHostBehindActiveReply(in: rig)
        rig.controller.ingest(firstAudioControl(.stopPlayback))

        try flushOnlyFrame(in: rig)

        rig.controller.idleNow = { start + .milliseconds(20) }
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        rig.controller.ingest(idleAudio(other, sequence: 1, final: true, byte: 21, endpoint: "other"))
        #expect(rig.controller.isMuted && rig.player.muted)
        #expect(rig.player.pending.isEmpty && rig.player.played.isEmpty)
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 20])
        #expect(rig.status(other) == "Stopped")
    }

    @Test func flushedSingleFrameReplyStillAdvancesQueue() throws {
        let rig = PausedReplyRig()
        let other = queueOtherHostBehindActiveReply(in: rig, final: true)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        rig.ingest(idleReply(), byte: 30)
        try flushOnlyFrame(in: rig)
        #expect(rig.status(other) == "Played")
        #expect(rig.player.pending.map(\.payload.bytes.first) == [30])
    }
}

private extension ReplyMuteAfterStopTests {
    // Drive the PCM renderer's callback and route-reset generation without starting an audio engine.
    func flushOnlyFrame(in rig: PausedReplyRig) throws {
        try #require(rig.player.pending.count == 1)
        let buffer = rig.player.pending.removeFirst()
        let renderer = PCM16AudioPlayer(retiring: ReplyAudioRenderingResource())
        let onPlayed = try #require(buffer.completion)
        let completion = renderer.frameCompletion(for: buffer.payload, onPlayed: onPlayed)
        let finished = try #require(completion)
        renderer.dropPlayout()
        finished()
    }

    func queueOtherHostBehindActiveReply(
        in rig: PausedReplyRig, sequence: Int = 0, final: Bool = false
    ) -> ReplyDescriptor {
        rig.ingest(idleReply(), byte: 10)
        var other = idleReply()
        other.hostID = "other-mac"
        rig.controller.ingest(firstAudioText(other, endpoint: "other"))
        rig.controller.ingest(idleAudio(other, sequence: sequence, final: final, byte: 20, endpoint: "other"))
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        return other
    }
}
