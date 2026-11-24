import Foundation
@testable import HailCore
import HailProtocol
import Testing

@MainActor
@Suite struct PausedReplayQueueTests {
    @Test func queuedPrefixNeverEntersPlayerBeforeReplayFinishes() async throws {
        let rig = PausedReplyRig(), first = idleReply(), refused = idleReply(), next = idleReply()
        rig.controller.pausedAudioBudget = .init(seconds: 900, bytes: 120_000)
        rig.ingest(first, byte: 10)
        try await rig.player.playNext()
        rig.controller.replayLatest()
        rig.controller.togglePause()
        rig.ingest(refused, final: false, byte: 20)
        rig.controller.togglePause()
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 10])
        rig.controller.togglePause()
        rig.ingest(refused, sequence: 1, byte: 21)
        rig.ingest(next, byte: 30)
        #expect(rig.status(refused) == "Audio not kept while paused")
        rig.controller.togglePause()
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 10])
        try await rig.player.playNext() // A's Replay completes and C can immediately enter the player.
        #expect(rig.status(next) == "Playing")
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 10, 30])
        try await rig.player.playNext()
        #expect(rig.player.played == rig.player.scheduled)
        #expect(rig.status(refused) == "Audio not kept while paused" && rig.controller.queue.isEmpty)
    }

    @Test func activeReplayCountsUntilPlayerCompletion() async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply(), third = idleReply()
        rig.controller.pausedAudioBudget = .init(seconds: 900, bytes: 120_000)
        rig.ingest(first, byte: 10)
        try await rig.player.playNext()
        rig.controller.replayLatest()
        rig.ingest(second, byte: 20) // Complete 60,000-byte B arrives while A's 60,000-byte Replay plays.
        rig.controller.togglePause()
        #expect(rig.controller.retainedPausedAudio.bytes == 120_000)
        rig.ingest(third, byte: 30)
        #expect(rig.status(third) == "Audio not kept while paused")
        #expect(rig.controller.retainedPausedAudio.bytes == 120_000)
        rig.controller.togglePause()
        try await rig.player.playNext()
        #expect(rig.status(second) == "Playing" && rig.controller.retainedPausedAudio.bytes == 60_000)
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [10, 10, 20])
        #expect(rig.controller.retainedPausedAudio.bytes == 0 && rig.controller.queue.isEmpty)
    }

    @Test func refusedChatEntryShowsBudgetLossWhileNextReplyOwnsControls() async throws {
        let rig = PausedReplyRig(), first = idleReply(), refused = idleReply(), next = idleReply()
        rig.controller.pausedAudioBudget = .init(seconds: 900, bytes: 120_000)
        rig.ingest(first, byte: 10)
        rig.controller.togglePause()
        let frame = Frame(timestamp: 0, target: refused.targetID, source: refused.hostID,
                          payload: .text(TextPayload(text: "Synthetic queued text", reply: refused)))
        let event = HostReplyEvent(endpointID: "main", frame: frame)
        let chat = ConversationLog()
        chat.noteReply(event)
        rig.controller.ingest(event)
        let entry = try #require(chat.entries.first)
        #expect(entry.speaker == .haili && entry.text == "Synthetic queued text")
        rig.ingest(refused, final: false, byte: 20)
        rig.ingest(refused, sequence: 1, byte: 21)
        rig.ingest(next, byte: 30)
        rig.controller.togglePause()
        try await rig.player.playNext()
        let controls = try #require(rig.controller.presentationForControls)
        #expect(controls.id == ReplyStreamKey(endpointID: "main", replyID: next.id).presentationID)
        #expect(rig.controller.statusForControls == "Playing")
        #expect(rig.controller.audioProblem(replyID: entry.id) == "Audio not kept while paused")
        #expect(rig.controller.audioProblem(replyID: controls.id) == nil)
        #expect(rig.controller.lostAudioStatuses[entry.id] == nil)
    }

    @Test(arguments: [true, false])
    func nextReplyGetsItsOwnAdmissionAfterMutedReplay(proactive: Bool) async throws {
        let rig = PausedReplyRig(), policy = ProactivePlaybackRig()
        try configureQuietCapture(policy, for: rig)
        let first = policy.audio(byte: 10)
        HostNoticeOrigin.$generation.withValue(policy.generation) { rig.controller.ingest(first) }
        try await rig.player.playNext()
        rig.controller.replayLatest()
        #expect(rig.player.pending.map(\.payload.bytes.first) == [10])
        rig.controller.toggleMute()

        let next = policy.audio(proactive: proactive, byte: 20, final: false)
        let reply = try #require(rig.controller.descriptor(in: next.frame))
        let tail = idleAudio(reply, sequence: 1, final: true, byte: 21, endpoint: next.endpointID)
        HostNoticeOrigin.$generation.withValue(policy.generation) {
            rig.controller.ingest(next)
            rig.controller.ingest(tail)
        }
        #expect(rig.player.cancelCount == 1 && rig.player.muted && policy.activity.isQuiet)
        if proactive {
            #expect(rig.controller.queue.map(\.replyID) == [reply.id] && rig.controller.activeKey == nil)
            #expect(rig.status(reply) == "Queued")
            #expect(rig.player.pending.isEmpty && rig.player.scheduled.map(\.bytes.first) == [10, 10])
            rig.controller.toggleMute() // No further frame, timer, or change in measured quiet.
        }
        #expect(rig.controller.activeKey?.replyID == reply.id)
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 10, 20, 21])
        #expect(rig.player.mutedWhenScheduled == [false, false, !proactive, !proactive])
        try await rig.player.playNext()
        #expect(rig.status(reply) != "Played")
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [10, 20, 21])
        #expect(rig.status(reply) == "Played" && rig.controller.queue.isEmpty)
    }

    @Test func pendingVoiceMuteTakesEffectBeforeUpdateAdmission() async throws {
        let rig = PausedReplyRig(), policy = ProactivePlaybackRig()
        try configureQuietCapture(policy, for: rig)
        rig.ingest(idleReply(), byte: 10)
        rig.controller.setReplyMute(true)
        let next = policy.audio(byte: 20)
        HostNoticeOrigin.$generation.withValue(policy.generation) { rig.controller.ingest(next) }
        try await rig.player.playNext() // The confirmation finishes and its pending mute becomes effective.
        #expect(rig.player.muted && rig.controller.activeKey == nil)
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        rig.controller.toggleMute()
        try await rig.player.playNext()
        #expect(rig.player.mutedWhenScheduled == [false, false])
        #expect(rig.player.played.map(\.bytes.first) == [10, 20])
    }

    private func configureQuietCapture(_ policy: ProactivePlaybackRig, for rig: PausedReplyRig) throws {
        rig.controller.proactive.activity = policy.activity
        rig.controller.proactive.captureSafe = { true }
        rig.controller.proactive.authorize = { _, _, _ in true }
        rig.controller.idleNow = { policy.clock.now() }
        try policy.makeQuiet()
    }
}
