import Foundation
@testable import HailCore
import HailProtocol
import Testing

@MainActor
@Suite struct PausedReplyLifecycleTests {
    @Test func deferredUpdateAdmitsTextOnlyThenNormalReplyWithoutAnIdleTimeout() async throws {
        let rig = PausedReplyRig(), first = idleReply(), refused = idleReply(), normal = idleReply()
        let policy = ProactivePlaybackRig()
        rig.controller.proactive.activity = policy.activity
        rig.controller.proactive.captureSafe = { true }
        rig.controller.proactive.authorize = { _, _, _ in true }
        rig.controller.idleNow = { policy.clock.now() }
        rig.controller.pausedAudioBudget = .init(seconds: 900, bytes: 120_000)
        rig.ingest(first, byte: 10)
        rig.controller.togglePause()
        let update = policy.audio()
        HostNoticeOrigin.$generation.withValue(policy.generation) { rig.controller.ingest(update) }
        let updatePresentation = try #require(rig.controller.latest)
        let updateID = try #require(updatePresentationReplyID(update))
        rig.ingest(refused, byte: 20)
        let refusedKey = ReplyStreamKey(endpointID: "main", replyID: refused.id)
        rig.controller.togglePause()
        rig.ingest(normal, byte: 30)
        #expect(rig.controller.queue.map(\.replyID).suffix(2) == [refused.id, normal.id])

        try await rig.player.playNext() // A completes; admission promotes text-only B past deferred U.
        #expect(rig.controller.completed.contains(refusedKey))
        #expect(rig.status(refused) == "Audio not kept while paused")
        #expect(rig.status(normal) == "Playing")
        #expect(rig.controller.queue.map(\.replyID) == [normal.id, updateID])
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 30])
        try await rig.player.playNext()
        #expect(rig.controller.status(for: updatePresentation) == "Waiting for a measured pause")
        #expect(rig.status(refused) == "Audio not kept while paused")
        try policy.makeQuiet()
        rig.controller.recheckProactivePlayback()
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [10, 30, 1])
        #expect(rig.controller.queue.isEmpty && rig.status(refused) == "Audio not kept while paused")
    }

    @Test func textOnlyNeverReplacesThePreviousCompleteReplay() async throws {
        let rig = PausedReplyRig(), first = idleReply(), refused = idleReply()
        rig.controller.pausedAudioBudget = .init(seconds: 900, bytes: 180_000)
        rig.ingest(first, final: false, byte: 10)
        rig.ingest(first, sequence: 1, byte: 11)
        rig.controller.togglePause()
        rig.ingest(refused, final: false, byte: 20)
        let refusedKey = ReplyStreamKey(endpointID: "main", replyID: refused.id)
        var retained = try #require(rig.controller.streams[refusedKey])
        rig.ingest(refused, sequence: 1, byte: 21)
        // Storage and eligibility are separate: even a retained snapshot cannot become Replay audio.
        retained.audioNotKeptWhilePaused = true
        retained.nextSequence = 1
        #expect(rig.controller.retainedReplayAudio(in: retained) == nil)
        retained.nextSequence = 0
        #expect(rig.controller.nextRetainedSegment(in: retained) == nil)
        rig.controller.togglePause()
        try await rig.player.playNext()
        try await rig.player.playNext()
        #expect(rig.controller.completed.contains(refusedKey))
        #expect(rig.status(refused) == "Audio not kept while paused")
        #expect(rig.controller.lastKey?.replyID == first.id)
        #expect(rig.controller.lastAudio.map(\.bytes.first) == [10, 11])
        rig.controller.replayLatest()
        #expect(rig.status(refused) == "Audio not kept while paused")
        try await rig.player.playNext()
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [10, 11, 10, 11])
        #expect(rig.status(first) == "Played" && rig.status(refused) == "Audio not kept while paused")
        rig.ingest(refused, sequence: 2, byte: 22)
        #expect(rig.player.pending.isEmpty)
    }

    private func updatePresentationReplyID(_ event: HostReplyEvent) -> UUID? {
        guard case .audio(let audio) = event.frame.payload else { return nil }
        return audio.reply?.id
    }
}
