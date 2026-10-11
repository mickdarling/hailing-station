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
        let stuck = reply(), next = reply()
        rig.controller.ingest(audio(stuck, sequence: 0, final: false, byte: 10))
        rig.controller.ingest(audio(next, sequence: 0, final: true, byte: 20))
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        // 1.25 s of audio, then just under the timeout: still waiting.
        rig.advance(by: .milliseconds(1_250) + .milliseconds(19_900))
        #expect(rig.player.scheduled.map(\.bytes.first) == [10])
        rig.advance(by: .milliseconds(200))
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 20])
        #expect(rig.status(of: stuck) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.player.cancelCount == 0) // anything still buffered plays out
        // A late frame of the ended stream does not start it again.
        rig.controller.ingest(audio(stuck, sequence: 1, final: true, byte: 11))
        #expect(rig.player.scheduled.map(\.bytes.first) == [10, 20])
        #expect(DeviceDiagnostics.playbackFailure(ReplyPlaybackController.abandonedStatus) == "stream_abandoned")
    }

    @Test func aSlowButLiveStreamIsNeverCut() {
        let rig = IdleRig()
        let slow = reply(), next = reply()
        rig.controller.ingest(audio(slow, sequence: 0, final: false, byte: 10))
        rig.controller.ingest(audio(next, sequence: 0, final: true, byte: 99))
        // A frame every 19 s, each 1.25 s of audio: the buffer runs dry for long stretches, but frames keep coming.
        for sequence in 1...10 {
            rig.advance(by: .seconds(19))
            #expect(!rig.player.scheduled.contains { $0.bytes.first == 99 })
            rig.controller.ingest(audio(slow, sequence: sequence, final: false, byte: UInt8(10 + sequence)))
        }
        rig.advance(by: .seconds(19))
        rig.controller.ingest(audio(slow, sequence: 11, final: true, byte: 21))
        #expect(rig.status(of: slow) != ReplyPlaybackController.abandonedStatus)
        #expect(rig.player.scheduled.count == 12)
        rig.player.completeReply()
        #expect(rig.player.scheduled.last?.bytes.first == 99)
    }

    @Test func aLongBufferIsNotCutWhileItPlays() {
        let rig = IdleRig()
        let long = reply()
        // 20 s of audio arrives at once (the pacing lead), then the frames pause for 30 s: still inside its time.
        for sequence in 0..<16 { rig.controller.ingest(audio(long, sequence: sequence, final: false, byte: 10)) }
        rig.advance(by: .seconds(30))
        #expect(rig.status(of: long) != ReplyPlaybackController.abandonedStatus)
        rig.advance(by: .seconds(11)) // 20 s of audio + 20 s timeout, plus a margin
        #expect(rig.status(of: long) == ReplyPlaybackController.abandonedStatus)
    }

    @Test func anotherStreamsFramesDoNotKeepTheHeadAlive() {
        let rig = IdleRig()
        let stuck = reply(), other = reply()
        rig.controller.ingest(audio(stuck, sequence: 0, final: false, byte: 10))
        for sequence in 0..<5 {
            rig.advance(by: .seconds(5))
            rig.controller.ingest(audio(other, sequence: sequence, final: false, byte: 30, endpoint: "other"))
        }
        #expect(rig.status(of: stuck) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.player.scheduled.map(\.bytes.first).contains(30))
    }

    @Test func aPausedStreamIsNotEnded() {
        let rig = IdleRig()
        let paused = reply()
        rig.controller.ingest(audio(paused, sequence: 0, final: false, byte: 10))
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
        let long = reply(), next = reply()
        for sequence in 0..<16 { rig.controller.ingest(audio(long, sequence: sequence, final: false, byte: 10)) }
        rig.controller.ingest(audio(next, sequence: 0, final: true, byte: 99))
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
}

@MainActor
private final class IdleRig {
    let player = IdlePlayer()
    let controller: ReplyPlaybackController
    private var now = ContinuousClock.now
    private struct Timer {
        let due: ContinuousClock.Instant
        let fire: @MainActor () -> Void
        var live = true
    }
    private var timers: [Timer] = []

    init() {
        controller = ReplyPlaybackController(player: player)
        controller.idleNow = { [unowned self] in now }
        controller.idleScheduler = { [unowned self] delay, fire in
            let index = timers.count
            timers.append(Timer(due: now.advanced(by: delay), fire: fire))
            return { [weak self] in self?.timers[index].live = false }
        }
    }

    /// Moves the clock on in 100 ms steps, firing every live timer that comes due on the way.
    func advance(by duration: Duration) {
        let end = now.advanced(by: duration)
        while now < end {
            now = min(end, now.advanced(by: .milliseconds(100)))
            for index in timers.indices where timers[index].live && timers[index].due <= now {
                timers[index].live = false
                timers[index].fire()
            }
        }
    }

    func status(of reply: ReplyDescriptor) -> String? {
        controller.replies.first { $0.id.hasSuffix(reply.id.uuidString.lowercased()) }.map(controller.status(for:))
    }
}

private final class IdlePlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var cancelCount = 0
    private var completions: [@MainActor @Sendable () -> Void] = []

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        if let onPlayed { completions.append(onPlayed) }
    }
    func cancel() { cancelCount += 1 }
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func completeReply() { completions.removeFirst()() }
}

private func reply() -> ReplyDescriptor {
    ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
}

private func audio(_ reply: ReplyDescriptor, sequence: Int, final: Bool, byte: UInt8,
                   endpoint: HostEndpoint.Identifier = "main") -> HostReplyEvent {
    var bytes = Data(count: 60_000)
    bytes[0] = byte
    let payload = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
        streamID: reply.audioStreamID, isFinal: final, bytes: bytes, reply: reply
    )
    let frame = Frame(timestamp: Int64(sequence), target: reply.targetID, source: reply.hostID,
                      payload: .audio(payload))
    return HostReplyEvent(endpointID: endpoint, frame: frame)
}
