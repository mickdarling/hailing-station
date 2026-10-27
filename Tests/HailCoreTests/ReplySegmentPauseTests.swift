import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor @Suite struct ReplySegmentPauseTests {
    @Test func markersWaitForPlaybackThenPauseForConfiguredTime() {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.segmentSettings = ReplySegmentSettings(pauseAfterSegment: 2)
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.controller.ingest(segmentAudio(reply, sequence: 1))
        rig.controller.ingest(idleAudio(reply, sequence: 2, final: true, byte: 3))
        #expect(rig.player.scheduled.map(\.sequence) == [0])
        #expect(rig.controller.segmentPause == nil) // Scheduled is not played.
        rig.advance(by: .seconds(30))
        #expect(rig.abandoned == 0)
        rig.player.completeReply()
        #expect(rig.controller.segmentPause?.segment == 1)
        #expect(rig.controller.isReplyAudioOutputBusy) // Echo mask spans intentional silence.
        #expect(!rig.controller.isPaused)
        rig.advance(by: .milliseconds(1_900))
        #expect(rig.player.scheduled.map(\.sequence) == [0])
        rig.advance(by: .milliseconds(100))
        #expect(rig.player.endedSegmentPauses.count == 1)
        #expect(rig.player.endedSegmentPauses.first?.waiting == false)
        #expect(rig.player.scheduled.map(\.sequence) == [0, 1])
        #expect(rig.controller.segmentPause == nil)
        rig.player.completeReply()
        #expect(rig.controller.segmentPause?.segment == 2)
        rig.advance(by: .seconds(2))
        #expect(rig.player.scheduled.map(\.sequence) == [0, 1, 2])
        rig.player.completeReply()
        #expect(!rig.controller.isReplyAudioOutputBusy)
        #expect(rig.abandoned == 0)
    }

    @Test func framesArrivingInTheWindowStayQueued() {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.player.completeReply()
        rig.advance(by: .milliseconds(1_000))
        rig.controller.ingest(idleAudio(reply, sequence: 1, final: true, byte: 2))
        #expect(rig.player.scheduled.count == 1)
        rig.advance(by: .milliseconds(500))
        #expect(rig.player.scheduled.map(\.sequence) == [0, 1])
    }

    @Test func unsegmentedReplySchedulesImmediatelyAsBefore() {
        let rig = IdleRig(), reply = idleReply()
        for sequence in 0...2 {
            rig.controller.ingest(idleAudio(reply, sequence: sequence, final: sequence == 2, byte: 1))
        }
        #expect(rig.player.scheduled.map(\.sequence) == [0, 1, 2])
        #expect(rig.controller.segmentPause == nil)
        rig.player.completeReply()
        #expect(rig.controller.activeKey == nil)
    }

    @Test func pauseAndInterruptionNeverAbandonAndGiveFreshIdleBudget() {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.segmentSettings = ReplySegmentSettings(pauseAfterSegment: 10)
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.advance(by: .seconds(60)) // Wait for actual playback, never wall-clock playback guesses.
        #expect(rig.abandoned == 0)
        rig.player.completeReply()
        rig.controller.audioInterruption(began: true)
        rig.advance(by: .seconds(9))
        #expect(rig.controller.segmentPause != nil)
        rig.controller.audioInterruption(began: false)
        #expect(rig.controller.idleWatch.heldRemaining != nil)
        rig.advance(by: .seconds(1))
        #expect(rig.controller.segmentPause == nil)
        rig.advance(by: .seconds(19))
        #expect(rig.player.endedSegmentPauses.count == 1)
        #expect(rig.player.endedSegmentPauses.first?.waiting == true)
        #expect(rig.player.endedSegmentPauses.first?.held == false)
        #expect(rig.abandoned == 0)
        rig.advance(by: .seconds(3))
        #expect(rig.abandoned == 1) // Missing final after the pause still gets a real watchdog.
    }

    @Test func explicitPauseOutlastsWindowAndDoesNotSupersedeOnNewFrames() {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.player.completeReply()
        rig.controller.togglePause()
        rig.controller.ingest(idleAudio(reply, sequence: 1, final: true, byte: 2))
        rig.advance(by: .seconds(40))
        #expect(rig.player.endedSegmentPauses.first?.held == true)
        #expect(rig.player.scheduled.count == 1)
        #expect(rig.abandoned == 0)
        rig.controller.togglePause()
        #expect(rig.player.scheduled.count == 2)
    }

    @Test func stoppingInPauseDropsTheWholeReplyAndLateFrames() {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.player.completeReply()
        rig.controller.ingest(idleAudio(reply, sequence: 1, final: false, byte: 2))
        rig.controller.stopPlayback(from: "main")
        #expect(rig.controller.segmentPause == nil)
        rig.controller.ingest(idleAudio(reply, sequence: 2, final: true, byte: 3))
        rig.advance(by: .seconds(40))
        #expect(rig.player.scheduled.count == 1)
        #expect(rig.player.cancelCount == 1)
        #expect(rig.player.endedSegmentPauses.isEmpty)
        #expect(!rig.controller.isReplyAudioOutputBusy)
        #expect(rig.abandoned == 0)
    }

    @Test func headsetStopAndMuteInPauseRetiresReply() {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.player.completeReply()
        #expect(rig.controller.stopAndMuteFromHeadset())
        rig.controller.ingest(idleAudio(reply, sequence: 1, final: true, byte: 2))
        rig.advance(by: .seconds(40))
        #expect(rig.controller.isMuted)
        #expect(rig.player.scheduled.count == 1)
        #expect(rig.controller.segmentPause == nil)
    }

    @Test func captureSuppressionOutlastsPauseAndPreventsScheduling() {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.player.completeReply()
        rig.controller.beginCaptureSuppression()
        rig.controller.ingest(idleAudio(reply, sequence: 1, final: true, byte: 2))
        rig.advance(by: .seconds(40))
        #expect(rig.player.scheduled.count == 1)
        #expect(rig.abandoned == 0)
        rig.controller.endCaptureSuppression()
        #expect(rig.player.scheduled.count == 2)
    }
}

func segmentAudio(_ reply: ReplyDescriptor, sequence: Int) -> HostReplyEvent {
    var event = idleAudio(reply, sequence: sequence, final: false, byte: UInt8(sequence + 1))
    if case .audio(var audio) = event.frame.payload {
        audio.isSegmentEnd = true
        event.frame.payload = .audio(audio)
    }
    return event
}
