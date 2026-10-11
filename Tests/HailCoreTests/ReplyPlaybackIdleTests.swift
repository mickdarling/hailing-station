import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #469: a reply stream whose terminal marker never comes is ended once its audio has played out and
/// `streamIdleTimeout` passes without a frame of its own, so later replies are not stuck behind it.
@MainActor
@Suite struct ReplyPlaybackIdleTests {
    private static let segment = 60_000 // 1.25 s of 24 kHz 16-bit mono

    @Test func aStreamWithNoTerminalMarkerIsEndedAndTheNextReplyPlays() {
        let rig = IdleRig()
        let stuck = idleReply(), next = idleReply()
        rig.controller.ingest(idleAudio(stuck, sequence: 0, final: false, byte: 10))
        rig.controller.ingest(idleAudio(next, sequence: 0, final: true, byte: 20))
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        // 1.25 s of audio, then just under the timeout: still waiting.
        rig.advance(by: .milliseconds(1_250) + .milliseconds(19_900))
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        rig.advance(by: .milliseconds(200))
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 20])
        #expect(rig.status(of: stuck) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.player.cancelCount == 0) // anything still buffered plays out
        // A late frame of the ended stream does not start it again.
        rig.controller.ingest(idleAudio(stuck, sequence: 1, final: true, byte: 11))
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 20])
        #expect(rig.abandoned == 1)
    }

    @Test func aSlowButLiveStreamIsNeverCut() {
        let rig = IdleRig()
        let slow = idleReply(), next = idleReply()
        rig.controller.ingest(idleAudio(slow, sequence: 0, final: false, byte: 10))
        rig.controller.ingest(idleAudio(next, sequence: 0, final: true, byte: 99))
        // A frame every 19 s, each 1.25 s of audio: the buffer runs dry for long stretches, but frames keep coming.
        for sequence in 1...10 {
            rig.advance(by: .seconds(19))
            #expect(!rig.player.scheduled.contains { $0.bytes.first == 99 })
            rig.controller.ingest(idleAudio(slow, sequence: sequence, final: false, byte: UInt8(10 + sequence)))
        }
        rig.advance(by: .seconds(19))
        rig.controller.ingest(idleAudio(slow, sequence: 11, final: true, byte: 21))
        #expect(rig.status(of: slow) != ReplyPlaybackController.abandonedStatus)
        #expect(rig.player.scheduled.count == 12)
        rig.player.completeReply()
        #expect(rig.player.scheduled.last?.bytes.first == 99)
    }

    @Test func aLongBufferIsNotCutWhileItPlays() {
        let rig = IdleRig()
        let long = idleReply()
        // 20 s of audio arrives at once (the pacing lead), then the frames pause for 30 s: still inside its time.
        for sequence in 0..<16 { rig.controller.ingest(idleAudio(long, sequence: sequence, final: false, byte: 10)) }
        rig.advance(by: .seconds(30))
        #expect(rig.status(of: long) != ReplyPlaybackController.abandonedStatus)
        rig.advance(by: .seconds(11)) // 20 s of audio + 20 s timeout, plus a margin
        #expect(rig.status(of: long) == ReplyPlaybackController.abandonedStatus)
    }

    /// #473 review: a head whose final segment is scheduled is finished, even if the player stalls far past the
    /// estimate (an interruption or route change). It waits for the player's completion and is never abandoned.
    @Test func aFinishedHeadWithAStalledPlayerIsNeverAbandoned() {
        let rig = IdleRig()
        let finished = idleReply(), next = idleReply()
        rig.controller.ingest(idleAudio(finished, sequence: 0, final: false, byte: 10))
        rig.controller.ingest(idleAudio(finished, sequence: 1, final: true, byte: 11))
        rig.controller.ingest(idleAudio(next, sequence: 0, final: true, byte: 99))
        rig.advance(by: .seconds(300))
        #expect(rig.status(of: finished) != ReplyPlaybackController.abandonedStatus)
        #expect(rig.controller.isReplyAudioOutputBusy) // still masked for the echo guard
        #expect(!rig.player.scheduled.contains { $0.bytes.first == 99 })
        rig.player.completeReply()
        #expect(rig.status(of: finished) == "Played")
        #expect(rig.player.scheduled.last?.bytes.first == 99)
    }

    /// Codex P2 on #473: with more than `presentationLimit` replies queued behind it, the ended head's status is
    /// trimmed at once; the diagnostic is recorded directly, exactly once.
    @Test func abandonmentIsRecordedEvenWhenItsStatusIsTrimmed() {
        let rig = IdleRig()
        let stuck = idleReply()
        rig.controller.ingest(idleAudio(stuck, sequence: 0, final: false, byte: 10))
        for _ in 0...ReplyPlaybackController.presentationLimit {
            rig.controller.ingest(idleAudio(idleReply(), sequence: 0, final: false, byte: 20))
        }
        rig.advance(by: .seconds(22))
        #expect(rig.abandoned == 1)
        // DeviceDiagnostics records it through this hook, not from the status.
        let suite = "hail-idle-diagnostics-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [.app: .token("0.1.87")], wallNow: { 5 })
        let controller = ReplyPlaybackController(player: IdlePlayer())
        #expect(controller.onStreamAbandoned == nil)
        log.watch(controller)
        #expect(controller.onStreamAbandoned != nil)
    }

    @Test func anotherStreamsFramesDoNotKeepTheHeadAlive() {
        let rig = IdleRig()
        let stuck = idleReply(), other = idleReply()
        rig.controller.ingest(idleAudio(stuck, sequence: 0, final: false, byte: 10))
        for sequence in 0..<5 {
            rig.advance(by: .seconds(5))
            rig.controller.ingest(idleAudio(other, sequence: sequence, final: false, byte: 30, endpoint: "other"))
        }
        #expect(rig.status(of: stuck) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.player.scheduled.map(\.bytes.first).contains(30))
    }
}
