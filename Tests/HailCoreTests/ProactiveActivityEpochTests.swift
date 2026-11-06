import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ProactiveActivityEpochTests {
    @Test func soundThenQuietBeforeMainCallbackPermanentlyRetiresStartedSpeech() throws {
        let rig = EpochPlaybackRig()
        try rig.quiet()
        rig.ingest()
        #expect(rig.player.scheduled.count == 1)
        try rig.sound()
        try rig.quiet()
        #expect(rig.activity.isQuiet)
        rig.controller.replayLatest()
        #expect(rig.controller.status == "Update available in conversation")
        rig.controller.recheckProactivePlayback()
        #expect(rig.player.cancelCount == 1 && rig.controller.queue.isEmpty)
        rig.ingest()
        #expect(rig.player.scheduled.count == 1)
    }

    @Test func missingBuffersThenFreshQuietCannotReviveStartedSpeech() throws {
        let rig = EpochPlaybackRig()
        try rig.quiet()
        rig.ingest()
        rig.clock.advance(by: .seconds(1))
        try rig.quiet()
        #expect(rig.activity.isQuiet)
        rig.controller.recheckProactivePlayback()
        #expect(rig.player.cancelCount == 1 && rig.controller.queue.isEmpty)
    }

    @Test func queuedSpeechMayAwaitFreshQuietUntilItActuallyStarts() throws {
        let rig = EpochPlaybackRig()
        rig.ingest()
        #expect(rig.player.scheduled.isEmpty)
        try rig.sound()
        try rig.quiet()
        rig.controller.recheckProactivePlayback()
        #expect(rig.player.scheduled.count == 1 && rig.player.cancelCount == 0)
    }
}

@MainActor
private final class EpochPlaybackRig {
    let clock = TestInstantClock()
    let player = IdlePlayer()
    let activity: ProactiveAudioActivity
    let controller: ReplyPlaybackController
    let token: UUID
    private let descriptor: ReplyDescriptor
    private let generation = UUID()

    init() {
        let clock = clock
        activity = ProactiveAudioActivity(now: { clock.now() })
        token = activity.beginCapture()
        controller = ReplyPlaybackController(player: player)
        controller.idleNow = { clock.now() }
        controller.idleScheduler = { _, _ in {} } // Deliberately withhold every main-actor watchdog callback.
        controller.proactive.activity = activity
        controller.proactive.captureSafe = { true }
        controller.proactive.authorize = { _, _, _ in true }
        let id = UUID()
        descriptor = ReplyDescriptor(id: id, hostID: "host", targetID: "tmux:build", audioStreamID: UUID(),
                                     priority: .background, sessionUpdateID: id)
    }

    func ingest() {
        HostNoticeOrigin.$generation.withValue(generation) {
            controller.ingest(idleAudio(descriptor, sequence: 0, final: true, byte: 1, endpoint: "mac"))
        }
    }

    func quiet() throws {
        for _ in 0..<60 { try observe(0); clock.advance(by: .milliseconds(10)) }
    }

    func sound() throws { try observe(0.1); clock.advance(by: .milliseconds(10)) }

    private func observe(_ value: Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<480 { samples[index] = value }
        activity.observe(buffer, capturedAt: clock.now(), capture: token)
    }
}
