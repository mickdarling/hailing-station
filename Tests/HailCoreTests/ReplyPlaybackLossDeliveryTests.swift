import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825 / #838: loss observation must survive a presentation update in the same main-actor turn.
@MainActor
@Suite struct ReplyPlaybackLossDeliveryTests {
    @Test(arguments: [true, false])
    func abandonedStreamSurvivesHistoryPressureUntilObserved(allowCue: Bool) async throws {
        let rig = IdleRig(), reply = idleReply()
        let renderer = CountingRenderer(), fallback = FirstAudioFallbacks(), observed = ObservedReplyLosses()
        let announcer = Announcer(playback: rig.controller, renderer: renderer) { fallback.record($0, $1) }
        announcer.watchReplyAudio { observed.record(rig.controller); return allowCue }
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
        #expect(renderer.rendered == (allowCue ? [.replyAudioLost] : []))
        #expect(rig.player.scheduled.count == (allowCue ? 2 : 1))
        #expect(fallback.announcements.isEmpty)
        if allowCue, rig.player.scheduled.count > 1 { rig.player.completeReply() }
        #expect(rig.controller.presentationKeysToRetain.isEmpty, "VoiceOver observations acknowledge losses too")
        announcer.watchReplyAudio { true }
        await settleFirstAudio()
        #expect(renderer.rendered.count == (allowCue ? 1 : 0), "an observed loss is never announced twice")
        rig.controller.ingest(lossRaceText())
        #expect(rig.controller.lostAudioStatuses[id] == nil, "the next trim uses ordinary history semantics")
        #expect(rig.controller.replies.count == ReplyPlaybackController.presentationLimit)
        withExtendedLifetime(announcer) {}
    }

    @Test func voiceOverObservationReleasesExpiredFirstAudioWithoutACue() async throws {
        let rig = IdleRig(), reply = idleReply(), renderer = CountingRenderer(), observed = ObservedReplyLosses()
        let announcer = Announcer(playback: rig.controller, renderer: renderer) { _, _ in
            Issue.record("VoiceOver owns this announcement")
        }
        announcer.watchReplyAudio { observed.record(rig.controller); return false }
        rig.controller.ingest(firstAudioText(reply))
        let id = try #require(rig.controller.replies.first?.id)
        for _ in 0...ReplyPlaybackController.presentationLimit { rig.controller.ingest(lossRaceText()) }
        await settleFirstAudio()
        rig.advance(by: .seconds(20))
        rig.controller.ingest(lossRaceText())
        await settleFirstAudio()
        #expect(observed.statuses[id] == ReplyPlaybackController.abandonedStatus)
        #expect(rig.controller.presentationKeysToRetain.isEmpty)
        announcer.watchReplyAudio { true }
        await settleFirstAudio()
        #expect(renderer.rendered.isEmpty)
        #expect(rig.player.scheduled.isEmpty)
        rig.controller.ingest(lossRaceText())
        #expect(rig.controller.lostAudioStatuses[id] == nil)
        withExtendedLifetime(announcer) {}
    }

    @Test func unconsumedLossesKeepOnlyABoundedWindowInArrivalOrder() {
        let rig = IdleRig()
        for _ in 0..<2 {
            let replies = (0..<(ReplyPlaybackController.seenFrameLimit + 2)).map { _ in idleReply() }
            for reply in replies { rig.controller.ingest(firstAudioText(reply)) }
            rig.advance(by: .seconds(20))
            #expect(rig.controller.presentationKeysToRetain.count == ReplyPlaybackController.seenFrameLimit)
            rig.controller.ingest(lossRaceText())
            #expect(rig.controller.lostAudioStatuses.count == ReplyPlaybackController.seenFrameLimit)
            #expect(rig.controller.replies.count == ReplyPlaybackController.seenFrameLimit + 1)
            #expect(rig.status(of: replies[0]) == nil, "the oldest unconsumed loss leaves the bounded window")
            #expect(rig.status(of: replies[1]) == nil)
            #expect(rig.status(of: replies[2]) == ReplyPlaybackController.abandonedStatus)
            #expect(rig.status(of: replies[replies.count - 1]) == ReplyPlaybackController.abandonedStatus)
        }
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
