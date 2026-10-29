import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ProactiveAudibilityRestorationTests {
    @Test func revokedCaptureSuppressionEndNeverResumesOldAudioEvenTransiently() throws {
        let rig = try AudibilityRig()
        rig.start()
        rig.controller.beginCaptureSuppression()
        rig.allowed = false
        rig.controller.endCaptureSuppression()
        #expect(rig.player.resumed.isEmpty && rig.player.cancels == 1)
    }

    @Test func revokedPauseResumeNeverResumesOldAudioEvenTransiently() throws {
        let rig = try AudibilityRig()
        rig.start()
        rig.controller.togglePause()
        rig.allowed = false
        rig.controller.togglePause()
        #expect(rig.player.resumed.isEmpty && rig.player.cancels == 1)
    }

    @Test func revokedUnmuteCancelsBeforeMakingTheOldClipAudible() throws {
        let rig = try AudibilityRig()
        rig.start()
        rig.controller.toggleMute()
        rig.allowed = false
        rig.controller.toggleMute()
        #expect(rig.player.unmuted.isEmpty && rig.player.cancels == 1)
        #expect(!rig.controller.isMuted)
    }

    @Test func coalescedSoundAndQuietCannotSlipThroughPauseResume() throws {
        let rig = try AudibilityRig()
        rig.start()
        rig.controller.togglePause()
        try rig.observe(0.1)
        rig.clock.advance(by: .milliseconds(10))
        try rig.quiet()
        #expect(rig.activity.isQuiet)
        rig.controller.togglePause()
        #expect(rig.player.resumed.isEmpty && rig.player.cancels == 1)
    }

    @Test func replayedCompletedUpdateStopsOnReceiptRevocationWhileStillQuiet() throws {
        let rig = try AudibilityRig()
        rig.start()
        rig.player.complete()
        rig.controller.replayLatest()
        #expect(rig.player.replacements == 1 && rig.controller.queue.isEmpty)
        rig.allowed = false
        rig.controller.recheckProactivePlayback()
        #expect(rig.player.cancels == 1 && rig.controller.activeKey == nil)
    }

    @Test func replayedCompletedUpdateStopsAfterCoalescedSoundThenQuiet() throws {
        let rig = try AudibilityRig()
        rig.start()
        rig.player.complete()
        rig.controller.replayLatest()
        try rig.observe(0.1)
        rig.clock.advance(by: .milliseconds(10))
        try rig.quiet()
        #expect(rig.activity.isQuiet)
        rig.controller.recheckProactivePlayback()
        #expect(rig.player.cancels == 1 && rig.controller.activeKey == nil)
    }

    @Test func ordinaryPauseAndMuteControlsKeepTheirExistingBehavior() throws {
        let rig = try AudibilityRig()
        rig.start(proactive: false)
        rig.allowed = false
        rig.controller.togglePause()
        rig.controller.togglePause()
        rig.controller.toggleMute()
        rig.controller.toggleMute()
        #expect(rig.player.resumed.count == 1 && rig.player.unmuted.count == 1 && rig.player.cancels == 0)
    }
}

@MainActor
private final class AudibilityRig {
    let clock = TestInstantClock()
    let activity: ProactiveAudioActivity
    let player = AudibilityPlayer()
    let controller: ReplyPlaybackController
    let token: UUID
    var allowed = true

    init() throws {
        let clock = clock
        activity = ProactiveAudioActivity(now: { clock.now() })
        token = activity.beginCapture()
        controller = ReplyPlaybackController(player: player)
        controller.idleNow = { clock.now() }
        controller.idleScheduler = { _, _ in {} } // Hold every observer/watchdog until the tested synchronous edge.
        controller.proactive.activity = activity
        controller.proactive.captureSafe = { true }
        controller.proactive.authorize = { [weak self] _, _, _ in self?.allowed == true }
        try quiet()
    }

    func start(proactive: Bool = true) {
        let id = UUID()
        let descriptor = ReplyDescriptor(id: id, hostID: "host", targetID: "tmux:build", audioStreamID: UUID(),
            priority: proactive ? .background : .normal, sessionUpdateID: proactive ? id : nil)
        HostNoticeOrigin.$generation.withValue(UUID()) {
            controller.ingest(idleAudio(descriptor, sequence: 0, final: true, byte: 1, endpoint: "mac"))
        }
    }

    func quiet() throws {
        for _ in 0..<60 { try observe(0); clock.advance(by: .milliseconds(10)) }
    }

    func observe(_ value: Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<480 { samples[index] = value }
        activity.observe(buffer, capturedAt: clock.now(), capture: token)
    }
}

@MainActor
private final class AudibilityPlayer: ReplyAudioPlaying {
    var resumed: [UUID] = []
    var unmuted: [UUID] = []
    var cancels = 0
    var replacements = 0
    private var completions: [@MainActor @Sendable () -> Void] = []
    private var active: UUID?
    private var paused = false
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        active = payload.reply?.id
        if let onPlayed { completions.append(onPlayed) }
    }
    func complete() { active = nil; completions.removeFirst()() }
    func cancel() { cancels += 1; active = nil; paused = false }
    func pause() { paused = true }
    func resume() { if let active { resumed.append(active) }; paused = false }
    func setMuted(_ muted: Bool) { if !muted, !paused, let active { unmuted.append(active) } }
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {
        replacements += 1
        active = payloads.last?.reply?.id
        if let onPlayed { completions.append(onPlayed) }
    }
}
