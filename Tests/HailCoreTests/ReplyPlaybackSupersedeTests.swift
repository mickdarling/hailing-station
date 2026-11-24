import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #1259 replaces #321's discard: synthetic player notifications prove FIFO and retained frames.
@MainActor
@Suite struct ReplyPlaybackSupersedeTests {
    @Test(arguments: [false, true])
    func aNewReplyWaitsForThePausedRemainder(finalBeforePause: Bool) async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply()
        rig.ingest(first, sequence: 0, final: false, byte: 10)
        rig.ingest(first, sequence: 1, final: finalBeforePause, byte: 11)
        try await rig.player.playNext() // The cursor has passed frame 0, but frame 1 remains buffered.
        rig.controller.togglePause()
        rig.ingest(second, byte: 20)
        if !finalBeforePause { rig.ingest(first, sequence: 2, byte: 12) }
        #expect(rig.controller.isPaused && rig.player.paused)
        #expect(rig.status(first) == "Paused" && rig.status(second) == "Queued")
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 11])
        #expect(rig.player.cancelCount == 0)

        rig.controller.togglePause()
        #expect(rig.player.resumeCount == 1 && !rig.player.paused)
        #expect(rig.status(first) == "Playing" && rig.status(second) == "Queued")
        try await rig.player.playNext()
        if !finalBeforePause { try await rig.player.playNext() }
        #expect(rig.status(first) == "Played" && rig.status(second) == "Playing")
        try await rig.player.playNext()
        #expect(rig.status(second) == "Played")
        #expect(rig.player.played.map(\.bytes.first) == (finalBeforePause ? [10, 11, 20] : [10, 11, 12, 20]))
        #expect(rig.player.played == rig.player.scheduled, "every frame played once, including the paused buffer")
    }

    @Test(arguments: [false, true])
    func threeRepliesKeepArrivalOrder(secondBeforePause: Bool) async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply(), third = idleReply()
        rig.ingest(first, byte: 10)
        if secondBeforePause { rig.ingest(second, byte: 20) }
        rig.controller.togglePause()
        if !secondBeforePause { rig.ingest(second, byte: 20) }
        rig.ingest(third, byte: 30)
        #expect(rig.status(first) == "Paused")
        #expect(rig.status(second) == "Queued" && rig.status(third) == "Queued")
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        rig.controller.togglePause()
        try await rig.player.playNext()
        #expect(rig.status(first) == "Played" && rig.status(second) == "Playing")
        #expect(rig.status(third) == "Queued")
        try await rig.player.playNext()
        #expect(rig.status(second) == "Played" && rig.status(third) == "Playing")
        try await rig.player.playNext()
        #expect(rig.status(third) == "Played")
        #expect(rig.player.played.map(\.bytes.first) == [10, 20, 30])
        #expect(rig.player.cancelCount == 0)
    }

    @Test(arguments: [false, true])
    func explicitStopDuringPauseDiscardsBothReplies(hostStop: Bool) async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply()
        rig.ingest(first, final: false, byte: 10)
        rig.controller.togglePause()
        rig.ingest(second, final: false, byte: 20)
        if hostStop { rig.controller.ingest(firstAudioControl(.stopPlayback)) } else {
            rig.controller.stopPlayback(from: nil)
        }
        #expect(rig.player.cancelCount == 1 && rig.player.pending.isEmpty)
        #expect(!rig.controller.isPaused)
        #expect(rig.status(first) == "Stopped" && rig.status(second) == "Stopped")
        rig.ingest(first, sequence: 1, byte: 11)
        rig.ingest(second, sequence: 1, byte: 21)
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        #expect(rig.player.played.isEmpty)
        let later = idleReply()
        rig.ingest(later, byte: 30)
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [30])
        #expect(rig.status(later) == "Played")
    }

    @Test func sessionUpdateDuringPauseKeepsItsExistingAdmissionPolicy() async throws {
        let rig = PausedReplyRig(), first = idleReply()
        let policy = ProactivePlaybackRig() // Injects measured quiet without wall-clock waits.
        rig.controller.proactive.activity = policy.activity
        rig.controller.proactive.captureSafe = { true }
        rig.controller.proactive.authorize = { _, _, _ in true }
        rig.controller.idleNow = { policy.clock.now() }
        rig.ingest(first, byte: 10)
        rig.controller.togglePause()
        let update = policy.audio()
        HostNoticeOrigin.$generation.withValue(policy.generation) { rig.controller.ingest(update) }
        let presentation = try #require(rig.controller.latest)
        #expect(presentation.isSessionUpdate)
        #expect(rig.controller.status(for: presentation) == "Queued")
        #expect(rig.status(first) == "Paused" && rig.player.cancelCount == 0)
        rig.controller.togglePause()
        try await rig.player.playNext()
        #expect(rig.controller.status(for: presentation) == "Waiting for a measured pause")
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        try policy.makeQuiet()
        rig.controller.recheckProactivePlayback()
        try await rig.player.playNext()
        #expect(rig.controller.status(for: presentation) == "Played")
        #expect(rig.player.played.map(\.bytes.first) == [10, 1])
    }

    @Test func pendingVoiceMuteStillWaitsForThePausedReplyToFinish() async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply()
        rig.ingest(first, byte: 10)
        rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true)))
        rig.controller.togglePause()
        rig.ingest(second, byte: 20)
        #expect(!rig.controller.isMuted && !rig.player.muted)
        rig.controller.togglePause()
        #expect(!rig.controller.isMuted)
        try await rig.player.playNext()
        #expect(rig.controller.isMuted && rig.player.muted)
        #expect(rig.player.mutedWhenScheduled == [false, true])
        try await rig.player.playNext()
        #expect(rig.status(first) == "Played" && rig.status(second) == "Played")
    }

    @Test func listeningEndingKeepsTheExplicitPauseAndBothReplies() async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply()
        rig.ingest(first, byte: 10)
        rig.controller.togglePause()
        rig.controller.beginCaptureSuppression()
        rig.ingest(second, byte: 20)
        rig.controller.endCaptureSuppression()
        #expect(rig.controller.isPaused && rig.player.resumeCount == 0)
        #expect(rig.status(first) == "Paused" && rig.status(second) == "Queued")
        rig.controller.togglePause()
        try await rig.player.playNext()
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [10, 20])
    }
}
