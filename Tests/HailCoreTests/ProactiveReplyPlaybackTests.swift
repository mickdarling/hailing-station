import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ProactiveReplyPlaybackTests {
    @Test func markedAudioNeedsAuthorizationAndMissingCaptureFailsClosed() {
        let rig = ProactivePlaybackRig()
        rig.allowed = false
        rig.ingest(rig.audio())
        #expect(rig.player.scheduled.isEmpty && rig.controller.queue.isEmpty)
        rig.allowed = true
        rig.ingest(rig.audio())
        #expect(rig.player.scheduled.isEmpty && rig.controller.queue.count == 1)
    }

    @Test func deferredUpdateDoesNotBlockOrInterruptAnOrdinaryReply() throws {
        let rig = ProactivePlaybackRig()
        rig.ingest(rig.audio())
        let ordinary = rig.audio(proactive: false, byte: 2)
        rig.ingest(ordinary)
        #expect(rig.player.scheduled.map(\.bytes.first) == [2])
        #expect(rig.player.cancelCount == 0)
        try rig.makeQuiet()
        rig.controller.recheckProactivePlayback()
        #expect(rig.player.scheduled.map(\.bytes.first) == [2])
        rig.player.completeReply()
        #expect(rig.player.scheduled.map(\.bytes.first) == [2, 1])
    }

    @Test func soundDuringProactiveSpeechCancelsOnlyThatSpeechAndNeverReplaysIt() throws {
        let rig = ProactivePlaybackRig()
        try rig.makeQuiet()
        let update = rig.audio()
        rig.ingest(update)
        rig.ingest(rig.audio(proactive: false, byte: 2))
        try rig.sound()
        rig.controller.recheckProactivePlayback()
        #expect(rig.player.cancelCount == 1)
        #expect(rig.player.scheduled.map(\.bytes.first) == [1, 2])
        #expect(rig.controller.lastKey?.replyID != update.frame.audioReplyID)
        rig.ingest(update)
        #expect(rig.player.scheduled.map(\.bytes.first) == [1, 2])
    }

    @Test func staleCaptureWatchStopsActiveSpeechWithoutWallClockSleep() throws {
        let rig = ProactivePlaybackRig()
        try rig.makeQuiet()
        rig.ingest(rig.audio())
        #expect(rig.player.scheduled.count == 1)
        rig.advance(by: .milliseconds(151))
        #expect(rig.player.cancelCount == 1)
        #expect(rig.controller.queue.isEmpty)
    }

    @Test func stoppingCaptureOrRevokingPolicyDoesNotCancelOrdinaryPlayback() throws {
        let rig = ProactivePlaybackRig()
        try rig.makeQuiet()
        rig.ingest(rig.audio(proactive: false, byte: 2))
        rig.ingest(rig.audio())
        rig.allowed = false
        rig.activity.endCapture(rig.capture)
        rig.controller.recheckProactivePlayback()
        #expect(rig.player.cancelCount == 0)
        #expect(rig.controller.queue.count == 1)
        #expect(rig.player.scheduled.map(\.bytes.first) == [2])
    }

    @Test func proactiveArrivalCannotSupersedeAPausedOrdinaryReply() {
        let rig = ProactivePlaybackRig()
        rig.ingest(rig.audio(proactive: false, byte: 2))
        rig.controller.togglePause()
        rig.ingest(rig.audio())
        #expect(rig.controller.isPaused)
        #expect(rig.player.cancelCount == 0)
        #expect(rig.controller.queue.count == 2)
    }

    @Test func aQuietPauseNeverRenewsAnExpiredSpeechCandidate() throws {
        let rig = ProactivePlaybackRig()
        rig.ingest(rig.audio())
        rig.advance(by: .seconds(31))
        try rig.makeQuiet()
        rig.controller.recheckProactivePlayback()
        #expect(rig.player.scheduled.isEmpty && rig.controller.queue.isEmpty)
    }
}

@MainActor
private final class ProactivePlaybackRig {
    let clock = TestInstantClock()
    let player = IdlePlayer()
    let controller: ReplyPlaybackController
    let activity: ProactiveAudioActivity
    let capture: UUID
    let generation = UUID()
    var allowed = true
    private var timers: [Int: (due: ContinuousClock.Instant, fire: @MainActor () -> Void)] = [:]
    private var next = 0

    init() {
        controller = ReplyPlaybackController(player: player)
        let clock = clock
        activity = ProactiveAudioActivity(now: { clock.now() })
        capture = activity.beginCapture()
        controller.idleNow = { clock.now() }
        controller.proactive.activity = activity
        controller.proactive.captureSafe = { true }
        controller.proactive.authorize = { [weak self] _, _, _ in self?.allowed == true }
        controller.idleScheduler = { [weak self] delay, fire in
            guard let self else { return {} }
            let token = next
            next += 1
            timers[token] = (clock.now().advanced(by: delay), fire)
            return { [weak self] in self?.timers[token] = nil }
        }
    }

    func audio(proactive: Bool = true, byte: UInt8 = 1) -> HostReplyEvent {
        let id = UUID()
        var reply = ReplyDescriptor(id: id, hostID: "host", targetID: "tmux:build", audioStreamID: UUID(),
                                    priority: proactive ? .background : .normal)
        reply.sessionUpdateID = proactive ? id : nil
        return idleAudio(reply, sequence: 0, final: true, byte: byte, endpoint: "mac")
    }

    func ingest(_ event: HostReplyEvent) {
        HostNoticeOrigin.$generation.withValue(generation) { controller.ingest(event) }
    }

    func makeQuiet() throws {
        for _ in 0..<60 {
            activity.observe(try buffer(0), capturedAt: clock.now(), capture: capture)
            clock.advance(by: .milliseconds(10))
        }
    }

    func sound() throws { activity.observe(try buffer(0.1), capturedAt: clock.now(), capture: capture) }

    private func buffer(_ value: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<480 { samples[index] = value }
        return buffer
    }

    func advance(by duration: Duration) {
        clock.advance(by: duration)
        for token in timers.keys.sorted() {
            guard let timer = timers[token], timer.due <= clock.now() else { continue }
            timers[token] = nil
            timer.fire()
        }
    }
}

private extension Frame {
    var audioReplyID: UUID? {
        guard case .audio(let payload) = self.payload else { return nil }
        return payload.reply?.id
    }
}
