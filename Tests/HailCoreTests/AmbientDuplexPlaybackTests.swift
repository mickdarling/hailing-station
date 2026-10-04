import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Full-duplex ambient listening (#227): replies play while the ambient microphone is open, and masking is already
/// up whenever the player is asked to make audio audible. Tap-to-talk capture still holds replies until it finishes.
@MainActor
@Suite struct AmbientDuplexPlaybackTests {
    @MainActor
    final class Harness {
        let clock = EchoGuardClock()
        lazy var echoGuard = AmbientReplyEchoGuard(tail: .milliseconds(400), now: { [clock] in clock.now })
        let player = DuplexPlayer()
        lazy var playback: ReplyPlaybackController = {
            player.echoGuard = echoGuard
            let playback = ReplyPlaybackController(player: echoGuard.guarding(player))
            echoGuard.follow(playback)
            return playback
        }()

        /// Lets the follower lower masking, then lets the tail elapse.
        func quiet() async {
            await settle()
            clock.advance(by: .milliseconds(400))
        }
    }

    @Test func repliesPlayImmediatelyWhileAmbientListeningIsOn() async throws {
        let capture = FakeAudioCapture()
        let ambient = AmbientListeningController(
            requestPermission: { true },
            makeStreamer: { send in AmbientAudioStreamer(capture: capture, send: send) },
            releaseSession: {},
            send: { _, _ in }
        )
        let harness = Harness()
        await ambient.turnOn(for: try binding())
        #expect(ambient.isListening)

        harness.playback.ingest(duplexEvent())
        #expect(harness.player.calls == [.init(name: "schedule", masking: true)])
        #expect(!harness.playback.isCaptureSuppressed)
        #expect(harness.playback.statusForControls == "Playing")
        #expect(ambient.isOn && ambient.isListening)
        await ambient.turnOff()
    }

    @Test func maskingIsUpBeforeTheFirstSegmentIsScheduled() {
        let harness = Harness()
        #expect(!harness.echoGuard.isMasking)
        harness.playback.ingest(duplexEvent())
        // No main-actor hop: the guarded player raised masking inside the same call.
        #expect(harness.player.calls.first == .init(name: "schedule", masking: true))
    }

    @Test func maskingIsUpBeforePausedPlaybackResumes() async {
        let harness = Harness()
        harness.playback.ingest(duplexEvent())
        harness.playback.togglePause()
        await harness.quiet()
        #expect(!harness.echoGuard.isMasking)

        harness.playback.togglePause()
        #expect(harness.player.calls.last == .init(name: "resume", masking: true))
        await settle()
        #expect(harness.echoGuard.isMasking)
    }

    @Test func maskingIsUpBeforeAMutedReplyIsUnmuted() async {
        let harness = Harness()
        harness.playback.toggleMute()
        harness.playback.ingest(duplexEvent())
        await harness.quiet()
        #expect(harness.player.calls.contains(.init(name: "schedule", masking: false)))
        #expect(!harness.echoGuard.isMasking)

        harness.playback.toggleMute()
        #expect(harness.player.calls.last == .init(name: "unmute", masking: true))
        await settle()
        #expect(harness.echoGuard.isMasking)
    }

    @Test func maskingIsUpBeforeAReplay() async {
        let harness = Harness()
        harness.playback.ingest(duplexEvent())
        harness.player.finish()
        #expect(!harness.playback.isReplyAudioOutputBusy)
        await harness.quiet()
        #expect(!harness.echoGuard.isMasking)

        harness.playback.replayLatest()
        #expect(harness.player.calls.last == .init(name: "replay", masking: true))
    }

    @Test func maskingFallsOnlyAfterTheTailOncePlaybackEnds() async {
        let harness = Harness()
        harness.playback.ingest(duplexEvent())
        harness.player.finish()
        await settle()
        harness.clock.advance(by: .milliseconds(399))
        #expect(harness.echoGuard.isMasking)
        harness.clock.advance(by: .milliseconds(1))
        #expect(!harness.echoGuard.isMasking)
    }

    @Test func tapToTalkCaptureStillHoldsReplyPlayback() async {
        let harness = Harness()
        harness.playback.beginCaptureSuppression()

        harness.playback.ingest(duplexEvent())
        await settle()
        #expect(harness.player.calls.isEmpty)
        #expect(harness.playback.isCaptureSuppressed)
        #expect(harness.playback.statusForControls == "Paused while listening")
        #expect(!harness.echoGuard.isMasking)

        harness.playback.endCaptureSuppression()
        #expect(harness.player.calls == [.init(name: "schedule", masking: true)])
        #expect(harness.playback.statusForControls == "Playing")
    }
}

/// Lets observation-driven Tasks on the main actor run.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

/// Records whether the echo guard was masking at the moment each audible-making call reached the player.
@MainActor
final class DuplexPlayer: ReplyAudioPlaying {
    struct Call: Equatable {
        var name: String
        var masking: Bool
    }

    var echoGuard: AmbientReplyEchoGuard?
    private(set) var calls: [Call] = []
    private var onPlayed: (@MainActor @Sendable () -> Void)?

    func schedule(_: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        record("schedule")
        if let onPlayed { self.onPlayed = onPlayed }
    }
    func resume() { record("resume") }
    func setMuted(_ muted: Bool) { if !muted { record("unmute") } }
    func replaceQueue(with _: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {
        record("replay")
        self.onPlayed = onPlayed
    }
    func finish() { onPlayed?() }
    func cancel() {}
    func pause() {}

    private func record(_ name: String) {
        calls.append(Call(name: name, masking: echoGuard?.isMasking == true))
    }
}

private func duplexEvent() -> HostReplyEvent {
    let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
    let audio = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0,
        streamID: reply.audioStreamID, isFinal: true, bytes: Data([1, 0]), reply: reply
    )
    return HostReplyEvent(
        endpointID: "main",
        frame: Frame(timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(audio))
    )
}
