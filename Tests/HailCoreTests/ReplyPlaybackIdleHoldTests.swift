import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #469: while nothing plays out (paused, listening, a phone call) or a replay plays first, the idle watch keeps a
/// stream's unplayed audio, so it never ends one whose audio is still due. Injected clock and scheduler.
@MainActor
@Suite struct ReplyPlaybackIdleHoldTests {
    /// Codex P1 on #473: a 26 s replay is playing when an unterminated reply arrives. Its audio is queued behind
    /// the replay, so its time starts after the replay ends, not at once.
    @Test func aReplyQueuedBehindAReplayIsNotEndedEarly() {
        let rig = IdleRig()
        let played = idleReply(), next = idleReply()
        for sequence in 0..<21 {
            rig.controller.ingest(idleAudio(played, sequence: sequence, final: sequence == 20, byte: 10))
        }
        rig.player.completeReply()
        rig.controller.replayLatest() // 21 x 1.25 s = 26.25 s
        rig.controller.ingest(idleAudio(next, sequence: 0, final: false, byte: 30))
        rig.advance(by: .seconds(46)) // 26.25 s replay + 1.25 s of its own + most of the 20 s timeout
        #expect(rig.status(of: next) != ReplyPlaybackController.abandonedStatus)
        rig.advance(by: .seconds(2))
        #expect(rig.status(of: next) == ReplyPlaybackController.abandonedStatus)
    }

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

    @Test func aPausedStreamIsNotEnded() {
        let rig = IdleRig()
        let paused = idleReply()
        rig.controller.ingest(idleAudio(paused, sequence: 0, final: false, byte: 10))
        rig.controller.togglePause()
        rig.advance(by: .seconds(120))
        #expect(rig.status(of: paused) != ReplyPlaybackController.abandonedStatus)
        rig.controller.togglePause()
        // Its 1.25 s of audio still plays after the pause, then the 20 s timeout.
        rig.advance(by: .seconds(21))
        #expect(rig.status(of: paused) != ReplyPlaybackController.abandonedStatus)
        rig.advance(by: .seconds(1))
        #expect(rig.status(of: paused) == ReplyPlaybackController.abandonedStatus)
    }

    /// Codex P1 on #473: 20 s buffered, paused 1 s in until long past the original deadline, then resumed. The
    /// 19 s still to play are kept across the pause, so the stream is not ended while that audio is audible.
    @Test(arguments: ["pause", "listening"])
    func aPauseKeepsTheUnplayedAudioOfAStream(hold: String) {
        let rig = IdleRig()
        let long = idleReply(), next = idleReply()
        for sequence in 0..<16 { rig.controller.ingest(idleAudio(long, sequence: sequence, final: false, byte: 10)) }
        rig.controller.ingest(idleAudio(next, sequence: 0, final: true, byte: 99))
        rig.advance(by: .seconds(1))
        if hold == "pause" { rig.controller.togglePause() } else { rig.controller.beginCaptureSuppression() }
        rig.advance(by: .seconds(60))
        if hold == "pause" { rig.controller.togglePause() } else { rig.controller.endCaptureSuppression() }
        rig.advance(by: .seconds(38)) // 19 s of audio and most of the 20 s timeout
        #expect(rig.status(of: long) != ReplyPlaybackController.abandonedStatus)
        #expect(!rig.player.scheduled.contains { $0.bytes.first == 99 })
        rig.advance(by: .seconds(2))
        #expect(rig.status(of: long) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.player.scheduled.last?.bytes.first == 99)
    }

    /// Codex P1 on #473: audio scheduled while held (during a call, or queued while paused and scheduled on resume)
    /// plays after the held audio. 5 s buffered, held 1 s in for a minute while 15 s more arrives: 19 s to play.
    @Test(arguments: ["pause", "interruption"])
    func audioScheduledDuringAHoldIsKept(hold: String) {
        let rig = IdleRig()
        let center = NotificationCenter()
        rig.controller.observeAudioInterruptions(on: center)
        let stream = idleReply()
        for sequence in 0..<4 { rig.controller.ingest(idleAudio(stream, sequence: sequence, final: false, byte: 10)) }
        rig.advance(by: .seconds(1))
        rig.hold(hold, true, on: center)
        rig.advance(by: .seconds(30))
        for sequence in 4..<16 { rig.controller.ingest(idleAudio(stream, sequence: sequence, final: false, byte: 10)) }
        rig.advance(by: .seconds(30))
        rig.hold(hold, false, on: center)
        rig.advance(by: .seconds(37)) // 19 s of audio and most of the 20 s timeout
        #expect(rig.status(of: stream) != ReplyPlaybackController.abandonedStatus)
        rig.advance(by: .seconds(3))
        #expect(rig.status(of: stream) == ReplyPlaybackController.abandonedStatus)
    }

    /// Codex P2 on #473: a second replay replaces the first in the player, so its backlog is not added to the first.
    @Test func aSecondReplayReplacesTheFirstsBacklog() {
        let rig = IdleRig()
        let played = idleReply(), next = idleReply()
        for sequence in 0..<21 {
            rig.controller.ingest(idleAudio(played, sequence: sequence, final: sequence == 20, byte: 10))
        }
        rig.player.completeReply()
        rig.controller.replayLatest()
        rig.controller.replayLatest() // 26.25 s again, not 52.5 s
        rig.controller.ingest(idleAudio(next, sequence: 0, final: false, byte: 30))
        rig.advance(by: .seconds(49))
        #expect(rig.status(of: next) == ReplyPlaybackController.abandonedStatus)
    }

    /// Codex round 5 (#469): an interruption that ends without the session resuming (no `shouldResume`, or a failed
    /// reactivation) leaves the player stopped, so the hold stays; neither the raw end notification nor that
    /// unresumed end releases it. Only a resume, or the app coming to the foreground, does.
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

    /// Codex round 5 (#469): a replay tapped while paused unpauses playback, so it releases the hold.
    @Test func aReplayTappedWhilePausedReleasesTheHold() {
        let rig = IdleRig()
        let played = idleReply(), next = idleReply()
        rig.controller.ingest(idleAudio(played, sequence: 0, final: true, byte: 10))
        rig.player.completeReply()
        rig.controller.togglePause()
        rig.controller.ingest(idleAudio(next, sequence: 1, final: false, byte: 30)) // a gap: queued, nothing plays
        rig.advance(by: .seconds(60))
        rig.controller.replayLatest() // 1.25 s
        rig.advance(by: .seconds(23))
        #expect(rig.status(of: next) == ReplyPlaybackController.abandonedStatus)
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

extension IdleRig {
    /// Starts or ends a pause, or an audio-session interruption: it begins on `center` and ends when the session
    /// reports playback resumed.
    func hold(_ kind: String, _ on: Bool, on center: NotificationCenter) {
        if kind == "pause" { return controller.togglePause() }
        guard on else { return controller.noteAudioSession(.interruptionEnded(resumed: true)) }
        center.post(name: ReplyPlaybackController.interruptionNotification, object: nil,
                    userInfo: [ReplyPlaybackController.interruptionTypeKey: UInt(1)])
    }
}
