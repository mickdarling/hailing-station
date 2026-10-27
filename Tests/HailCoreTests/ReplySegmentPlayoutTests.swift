import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite struct ReplySegmentPlayoutTests {
    @Test func boundaryNeitherStallsNorTrainsAdaptivePolicy() throws {
        var playout = ReplyPlayoutBuffer()
        let reply = idleReply()
        let marker = try #require(audio(segmentAudio(reply, sequence: 0)))
        let next = try #require(audio(segmentAudio(reply, sequence: 1)))
        let markerPlays = playout.queued([.milliseconds(100)], payload: marker)
        #expect(markerPlays)
        let markerStalls = playout.played(.milliseconds(100), segmentEnd: true)
        #expect(!markerStalls)
        #expect(!playout.isCatchingUp)
        #expect(playout.policy.target == .zero)
        #expect(playout.ahead == .zero)
        let nextPlays = playout.queued([.milliseconds(100)], payload: next)
        #expect(nextPlays)
        let nextStalls = playout.played(.milliseconds(100), segmentEnd: true)
        #expect(!nextStalls)
        #expect(playout.policy.target == .zero)
    }

    @Test func shortSegmentTailReleasesExistingCatchUpHold() throws {
        var playout = ReplyPlayoutBuffer()
        let reply = idleReply()
        let marker = try #require(audio(segmentAudio(reply, sequence: 1)))
        let firstPlays = playout.queued([.milliseconds(100)], startsReply: true, endsReply: false)
        #expect(firstPlays)
        let firstStalls = playout.played(.milliseconds(100)) // A genuine earlier network stall.
        #expect(firstStalls)
        let target = playout.policy.target
        #expect(target > .milliseconds(100))
        let markerPlays = playout.queued([.milliseconds(100)], payload: marker)
        #expect(markerPlays)
        #expect(!playout.isCatchingUp) // Never wait for audio the controller intentionally withholds.
        let markerStalls = playout.played(.milliseconds(100), segmentEnd: true)
        #expect(!markerStalls)
        #expect(playout.policy.target == target)
    }

    @Test func plannedPauseNeverBecomesAPlayoutGap() {
        let start = ContinuousClock.now
        var meter = PlayoutGapMeter()
        meter.scheduled(.seconds(1), at: start, startsReply: true)
        meter.paused(at: start + .seconds(1))
        var playout = ReplyPlayoutBuffer()
        let stalled = playout.endSegmentPause(at: start + .seconds(11), waitingForAudio: false, gapMeter: &meter)
        #expect(!stalled)
        #expect(playout.policy.target == .zero)
        meter.scheduled(.seconds(1), at: start + .seconds(11), startsReply: false)
        #expect(meter.take().count == 0)
        // A subsequent genuine underrun still counts.
        meter.scheduled(.seconds(1), at: start + .seconds(13), startsReply: false)
        #expect(meter.take().count == 1)
    }

    @Test func lateFrameCountsOnlySilenceAfterThePauseDeadlineAndTrainsStallRecovery() {
        let start = ContinuousClock.now
        var meter = PlayoutGapMeter(), playout = ReplyPlayoutBuffer()
        meter.scheduled(.seconds(1), at: start - .seconds(1), startsReply: true)
        meter.paused(at: start)
        let stalled = playout.endSegmentPause(
            at: start + .milliseconds(1_500), waitingForAudio: true, gapMeter: &meter
        )
        #expect(stalled)
        #expect(playout.isCatchingUp)
        #expect(playout.policy.target == .milliseconds(1_500))
        let plays = playout.queued([.seconds(2)], startsReply: false, endsReply: false)
        #expect(plays)
        // As in the player, a catch-up restart must preserve the deadline's gap accounting.
        meter.scheduled(.seconds(2), at: start + .seconds(7), startsReply: false)
        let gaps = meter.take()
        #expect(gaps.count == 1)
        #expect(gaps.total == .milliseconds(5_500))
    }
}

private func audio(_ event: HostReplyEvent) -> AudioPayload? {
    if case .audio(let audio) = event.frame.payload { return audio }
    return nil
}
