import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #469: an audio-session interruption (a phone call) stops the player without pausing it, so it holds the idle watch
/// until playback can resume. Injected clock and scheduler.
@MainActor
@Suite struct ReplyPlaybackIdleInterruptionTests {
    /// Codex P1 on #473: a phone call stops the player without pausing it. 20 s buffered, interrupted 1 s in for a
    /// minute: the 19 s still to play are kept, so the stream is not ended while that audio is due.
    @Test func anAudioInterruptionKeepsTheUnplayedAudioOfAStream() {
        let rig = IdleRig()
        let center = NotificationCenter()
        rig.controller.observeAudioInterruptions(on: center)
        let long = idleReply()
        for sequence in 0..<16 { rig.controller.ingest(idleAudio(long, sequence: sequence, final: false, byte: 10)) }
        rig.advance(by: .seconds(1))
        center.post(name: ReplyPlaybackController.interruptionNotification, object: nil,
                    userInfo: [ReplyPlaybackController.interruptionTypeKey: UInt(1)])
        rig.advance(by: .seconds(60))
        #expect(rig.status(of: long) != ReplyPlaybackController.abandonedStatus)
        rig.controller.noteAudioSession(.interruptionEnded(resumed: true))
        rig.advance(by: .seconds(38))
        #expect(rig.status(of: long) != ReplyPlaybackController.abandonedStatus)
        rig.advance(by: .seconds(2))
        #expect(rig.status(of: long) == ReplyPlaybackController.abandonedStatus)
    }

    /// Codex P1 on #478: reply-only playback activates the session itself, so no managed-session result comes; the
    /// notification's own end with `shouldResume` releases the hold. A failed reactivation reported later holds again.
    @Test func anEndWithShouldResumeReleasesTheHoldUnlessTheSessionFails() {
        let rig = IdleRig()
        let center = NotificationCenter()
        rig.controller.observeAudioInterruptions(on: center)
        let stream = idleReply()
        rig.controller.ingest(idleAudio(stream, sequence: 0, final: false, byte: 10))
        rig.hold("interruption", true, on: center)
        rig.advance(by: .seconds(60))
        center.post(name: ReplyPlaybackController.interruptionNotification, object: nil, userInfo: [
            ReplyPlaybackController.interruptionTypeKey: UInt(0), ReplyPlaybackController.interruptionOptionKey: UInt(1)
        ])
        rig.controller.noteAudioSession(.interruptionEnded(resumed: false))
        rig.advance(by: .seconds(60))
        #expect(rig.status(of: stream) != ReplyPlaybackController.abandonedStatus) // the session could not resume
        center.post(name: ReplyPlaybackController.interruptionNotification, object: nil, userInfo: [
            ReplyPlaybackController.interruptionTypeKey: UInt(0), ReplyPlaybackController.interruptionOptionKey: UInt(1)
        ])
        rig.advance(by: .seconds(22)) // reply-only: the notification alone ends the hold
        #expect(rig.status(of: stream) == ReplyPlaybackController.abandonedStatus)
    }

    @Test func anInterruptionEndedWithoutAResumeKeepsTheHold() {
        let rig = IdleRig()
        let center = NotificationCenter()
        rig.controller.observeAudioInterruptions(on: center)
        let stream = idleReply()
        rig.controller.ingest(idleAudio(stream, sequence: 0, final: false, byte: 10))
        rig.hold("interruption", true, on: center)
        center.post(name: ReplyPlaybackController.interruptionNotification, object: nil,
                    userInfo: [ReplyPlaybackController.interruptionTypeKey: UInt(0)])
        rig.controller.noteAudioSession(.interruptionEnded(resumed: false))
        rig.advance(by: .seconds(120))
        #expect(rig.status(of: stream) != ReplyPlaybackController.abandonedStatus)
        rig.controller.noteAudioSession(.interruptionEnded(resumed: true))
        rig.advance(by: .seconds(22))
        #expect(rig.status(of: stream) == ReplyPlaybackController.abandonedStatus)
    }

    /// #473 review: an interruption whose end is never posted is cleared when the app comes to the foreground.
    @Test func comingToTheForegroundEndsAStaleInterruptionHold() {
        let rig = IdleRig()
        let center = NotificationCenter()
        rig.controller.observeAudioInterruptions(on: center)
        let stream = idleReply()
        rig.controller.ingest(idleAudio(stream, sequence: 0, final: false, byte: 10))
        rig.hold("interruption", true, on: center)
        rig.advance(by: .seconds(120))
        #expect(rig.status(of: stream) != ReplyPlaybackController.abandonedStatus)
        center.post(name: ReplyPlaybackController.foregroundNotification, object: nil)
        rig.advance(by: .seconds(22)) // its 1.25 s of audio, then the 20 s timeout
        #expect(rig.status(of: stream) == ReplyPlaybackController.abandonedStatus)
    }
}
