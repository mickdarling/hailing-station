import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825 / #838: loss observation must survive a presentation update in the same main-actor turn.
@MainActor
@Suite struct ReplyPlaybackLossDeliveryTests {
    @Test func abandonedStreamSurvivesHistoryPressureUntilObserved() async throws {
        let rig = IdleRig(), reply = idleReply()
        let renderer = CountingRenderer(), fallback = FirstAudioFallbacks(), observed = ObservedReplyLosses()
        let announcer = Announcer(playback: rig.controller, renderer: renderer) { fallback.record($0, $1) }
        announcer.watchReplyAudio { observed.record(rig.controller); return true }
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: false, byte: 7))
        let id = try #require(rig.controller.replies.first?.id)
        for _ in 0...ReplyPlaybackController.presentationLimit { rig.controller.ingest(lossRaceText()) }
        await settleFirstAudio()
        rig.advance(by: .seconds(25)) // includes the stream's 1.25 seconds of buffered audio
        rig.controller.ingest(lossRaceText()) // no yield between abandonment and trimming
        #expect(rig.abandoned == 1)
        #expect(rig.controller.lostAudioStatuses[id] == ReplyPlaybackController.abandonedStatus)
        await settleFirstAudio()
        #expect(observed.statuses[id] == ReplyPlaybackController.abandonedStatus)
        #expect(renderer.rendered == [.replyAudioLost])
        #expect(rig.player.scheduled.count == 2)
        #expect(fallback.announcements.isEmpty)
        if rig.player.scheduled.count > 1 { rig.player.completeReply() }
        #expect(rig.controller.presentationKeysToRetain.isEmpty, "the Announcer acknowledged its delivery")
        announcer.watchReplyAudio { true }
        await settleFirstAudio()
        #expect(renderer.rendered.count == 1, "an observed loss is never announced twice")
        rig.controller.ingest(lossRaceText())
        #expect(rig.controller.lostAudioStatuses[id] == nil, "the next trim uses ordinary history semantics")
        #expect(rig.controller.replies.count == ReplyPlaybackController.presentationLimit)
        withExtendedLifetime(announcer) {}
    }

    @Test(arguments: [false, true], [false, true])
    func voiceOverLossSurvivesDeferredEligibilityCheck(midStream: Bool, watchBeforeLoss: Bool) async throws {
        let rig = IdleRig(), reply = idleReply(), renderer = CountingRenderer(), observed = ObservedReplyLosses()
        let announcer = Announcer(playback: rig.controller, renderer: renderer) { _, _ in
            Issue.record("VoiceOver owns this announcement")
        }
        if watchBeforeLoss { announcer.watchReplyAudio { observed.record(rig.controller); return false } }
        if midStream {
            rig.controller.ingest(idleAudio(reply, sequence: 0, final: false, byte: 7))
        } else {
            rig.controller.ingest(firstAudioText(reply))
        }
        let id = try #require(rig.controller.replies.first?.id)
        for _ in 0...ReplyPlaybackController.presentationLimit { rig.controller.ingest(lossRaceText()) }
        await settleFirstAudio()
        rig.advance(by: .seconds(25))
        rig.controller.ingest(lossRaceText())
        if !watchBeforeLoss { announcer.watchReplyAudio { observed.record(rig.controller); return false } }
        await settleFirstAudio()
        #expect(observed.statuses[id] == ReplyPlaybackController.abandonedStatus)
        // Model the app's deferred eligibility check after capture or another reply holds VoiceOver (#825, #86).
        for _ in 0..<3 {
            for _ in 0...ReplyPlaybackController.presentationLimit { rig.controller.ingest(lossRaceText()) }
            await settleFirstAudio()
            #expect(rig.controller.lostAudioStatuses[id] == observed.statuses[id])
            #expect(rig.controller.lostAudioStatuses[id] == ReplyPlaybackController.abandonedStatus)
            #expect(rig.controller.presentationKeysToRetain.count == 1)
        }
        announcer.watchReplyAudio { true }
        await settleFirstAudio()
        #expect(renderer.rendered.isEmpty)
        #expect(rig.player.scheduled.count == (midStream ? 1 : 0))
        rig.controller.ingest(lossRaceText())
        #expect(rig.controller.lostAudioStatuses[id] == ReplyPlaybackController.abandonedStatus)
        withExtendedLifetime(announcer) {}
    }

    @Test(arguments: [false, true])
    func unconsumedLossesKeepOnlyABoundedWindowInArrivalOrder(voiceOver: Bool) async {
        let rig = IdleRig(), renderer = CountingRenderer()
        let announcer = voiceOver ? Announcer(playback: rig.controller, renderer: renderer) { _, _ in
            Issue.record("an unconsumed loss must not produce an Announcer fallback")
        } : nil
        announcer?.watchReplyAudio { false }
        rig.controller.firstAudioClaimLimit = 4
        for _ in 0..<2 {
            let replies = (0..<(rig.controller.firstAudioClaimLimit + 2)).map { _ in idleReply() }
            for reply in replies { rig.controller.ingest(firstAudioText(reply)) }
            rig.advance(by: .seconds(20))
            await settleFirstAudio()
            #expect(rig.controller.presentationKeysToRetain.count == rig.controller.firstAudioClaimLimit)
            for _ in 0...ReplyPlaybackController.presentationLimit { rig.controller.ingest(lossRaceText()) }
            #expect(rig.controller.lostAudioStatuses.count == rig.controller.firstAudioClaimLimit)
            #expect(rig.controller.replies.count == ReplyPlaybackController.presentationLimit)
            #expect(rig.status(of: replies[0]) == nil, "the oldest unconsumed loss leaves the bounded window")
            #expect(rig.status(of: replies[1]) == nil)
            #expect(rig.status(of: replies[2]) == ReplyPlaybackController.abandonedStatus)
            #expect(rig.status(of: replies[replies.count - 1]) == ReplyPlaybackController.abandonedStatus)
        }
        #expect(renderer.rendered.isEmpty)
        #expect(rig.player.scheduled.isEmpty)
        withExtendedLifetime(announcer) {}
    }
}

@MainActor
final class ObservedReplyLosses {
    var statuses: [String: String] = [:]
    func record(_ controller: ReplyPlaybackController) {
        statuses.merge(controller.lostAudioStatuses) { _, new in new }
    }
}

func lossRaceText() -> HostReplyEvent {
    firstAudioText(ReplyDescriptor(id: UUID(), hostID: "host", targetID: "target"))
}

@MainActor
func playLossCues(_ rig: IdleRig, count: Int) {
    for index in 0..<count where rig.player.scheduled.count > index { rig.player.completeReply() }
    #expect(rig.player.scheduled.count == count, "every rendered cue reaches the reply player exactly once")
}
