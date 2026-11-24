import Foundation
@testable import HailCore
import HailProtocol
import Testing

@Suite @MainActor
struct PausedReplyBudgetTests {
    @Test func defaultBudgetIsFifteenMinutesAndSixtyFourMiB() {
        let controller = PausedReplyRig().controller
        #expect(controller.pausedAudioBudget.seconds == 900)
        #expect(controller.pausedAudioBudget.bytes == 67_108_864)
    }

    @Test(arguments: [false, true])
    func pressureKeepsAudioAndTextInFIFO(byteLimit: Bool) async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply(), third = idleReply()
        rig.controller.pausedAudioBudget = .init(seconds: byteLimit ? 900 : 2.5,
                                                bytes: byteLimit ? 120_000 : 67_108_864)
        rig.ingest(first, byte: 10)
        rig.controller.togglePause()
        rig.ingest(second, byte: 20)
        if byteLimit { text(third, into: rig) }
        rig.ingest(third, final: false, byte: 30)
        if !byteLimit { text(third, into: rig) }
        rig.ingest(third, sequence: 1, byte: 31)
        let thirdKey = ReplyStreamKey(endpointID: "main", replyID: third.id)
        #expect(rig.controller.queue.map(\.replyID) == [first.id, second.id, third.id])
        #expect(rig.controller.retainedPausedAudio.bytes == 120_000)
        #expect(rig.controller.retainedPausedAudio.seconds == 2.5)
        #expect(rig.controller.streams[thirdKey]?.segments.isEmpty == true)
        #expect(rig.status(third) == "Audio not kept while paused")
        #expect(rig.controller.latest?.transcript == "Synthetic queued text")
        #expect(rig.player.cancelCount == 0)

        rig.controller.togglePause()
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        try await rig.player.playNext()
        #expect(rig.status(first) == "Played" && rig.status(second) == "Playing")
        #expect(rig.controller.queue.map(\.replyID) == [second.id, third.id])
        #expect(rig.controller.retainedPausedAudio.bytes == 60_000)
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [10, 20])
        #expect(rig.status(second) == "Played" && rig.status(third) == "Audio not kept while paused")
        #expect(rig.controller.queue.isEmpty && rig.controller.retainedPausedAudio.bytes == 0)
        #expect(rig.controller.completed.contains(thirdKey))
        #expect(rig.controller.presentationForControls?.id == thirdKey.presentationID)
        #expect(rig.controller.statusForControls == "Audio not kept while paused")
        rig.ingest(third, sequence: 2, byte: 32)
        #expect(rig.player.pending.isEmpty)
    }

    @Test func durationUsesEachFramesPCMFormat() {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply(), third = idleReply()
        rig.controller.pausedAudioBudget = .init(seconds: 1.875, bytes: 67_108_864)
        rig.ingest(first, byte: 10) // 60,000 / (24,000 * 1 * 2) = 1.25 s.
        rig.controller.togglePause()
        var event = idleAudio(second, sequence: 0, final: true, byte: 20)
        if case .audio(var audio) = event.frame.payload {
            audio.sampleRate = 48_000 // Same byte count, 0.625 s; exactly fits.
            event.frame.payload = .audio(audio)
        }
        rig.controller.ingest(event)
        rig.ingest(third, byte: 30)
        #expect(rig.status(second) == "Queued")
        #expect(rig.status(third) == "Audio not kept while paused")
        #expect(rig.controller.retainedPausedAudio.seconds == 1.875)
    }

    @Test func pausedReplyIsKeptEvenWhenItAloneExceedsBudget() async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply()
        rig.controller.pausedAudioBudget = .init(seconds: 0, bytes: 0)
        rig.ingest(first, final: false, byte: 10)
        rig.controller.togglePause()
        rig.ingest(first, sequence: 1, byte: 11)
        rig.ingest(second, byte: 20)
        #expect(rig.controller.retainedPausedAudio.bytes == 120_000)
        #expect(rig.status(first) == "Paused" && rig.status(second) == "Audio not kept while paused")
        rig.controller.togglePause()
        try await rig.player.playNext()
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [10, 11])
        #expect(rig.controller.queue.isEmpty)
    }

    @Test func overflowDiscardsTheWholeReplyIncludingGappedFragments() async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply(), third = idleReply()
        rig.controller.pausedAudioBudget = .init(seconds: 900, bytes: 180_000)
        rig.ingest(first, byte: 10)
        rig.controller.togglePause()
        rig.ingest(second, final: false, byte: 20)
        rig.ingest(second, sequence: 2, final: false, byte: 22)
        rig.ingest(second, sequence: 1, final: false, byte: 21) // Any overflow makes all of B text-only.
        let key = ReplyStreamKey(endpointID: "main", replyID: second.id)
        #expect(rig.controller.streams[key]?.segments.isEmpty == true)
        #expect(rig.controller.retainedPausedAudio.bytes == 60_000)
        rig.ingest(second, sequence: 3, byte: 23)
        rig.ingest(third, byte: 30) // B released its budget, so C fits.
        #expect(rig.controller.retainedPausedAudio.bytes == 120_000)
        #expect(rig.status(second) == "Audio not kept while paused" && rig.status(third) == "Queued")
        rig.controller.togglePause()
        try await rig.player.playNext()
        #expect(rig.controller.completed.contains(key))
        #expect(rig.status(second) == "Audio not kept while paused" && rig.status(third) == "Playing")
        rig.ingest(second, sequence: 4, byte: 24) // Even after resume, no late B audio can play.
        try await rig.player.playNext()
        #expect(rig.player.played.map(\.bytes.first) == [10, 30])
        #expect(rig.player.scheduled == rig.player.played)
        #expect(rig.controller.queue.isEmpty)
    }

    @Test(arguments: [false, true])
    func budgetIsReusableAfterPlaybackOrStop(stop: Bool) async throws {
        let rig = PausedReplyRig(), first = idleReply(), second = idleReply(), third = idleReply()
        rig.controller.pausedAudioBudget = .init(seconds: 2.5, bytes: 120_000)
        rig.ingest(first, byte: 10)
        rig.controller.togglePause()
        rig.ingest(second, byte: 20)
        rig.ingest(third, byte: 30)
        if stop {
            rig.controller.stopPlayback(from: nil)
            #expect(rig.status(first) == "Stopped" && rig.status(second) == "Stopped")
            #expect(rig.status(third) == "Stopped")
            #expect(rig.controller.retainedPausedAudio.bytes == 0)
        } else {
            rig.controller.togglePause()
            try await rig.player.playNext() // Releases A while B is still playing.
        }
        let next = idleReply(), fits = idleReply()
        if stop { rig.ingest(next, byte: 40) }
        rig.controller.togglePause()
        rig.ingest(fits, byte: 50)
        #expect(rig.status(fits) == "Queued")
        #expect(rig.controller.retainedPausedAudio.bytes == 120_000)
        rig.controller.togglePause()
        try await rig.player.playNext()
        try await rig.player.playNext()
        #expect(rig.player.played.suffix(2).map(\.bytes.first) == (stop ? [40, 50] : [20, 50]))
        #expect(rig.status(third) == (stop ? "Stopped" : "Audio not kept while paused"))
        #expect(rig.controller.queue.isEmpty && rig.controller.retainedPausedAudio.bytes == 0)
    }

    private func text(_ reply: ReplyDescriptor, into rig: PausedReplyRig) {
        let frame = Frame(timestamp: 0, target: reply.targetID, source: reply.hostID,
                          payload: .text(TextPayload(text: "Synthetic queued text", reply: reply)))
        rig.controller.ingest(HostReplyEvent(endpointID: "main", frame: frame))
    }
}
