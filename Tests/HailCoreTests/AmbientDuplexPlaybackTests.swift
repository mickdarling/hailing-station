import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Full-duplex ambient listening (#227): replies play while the ambient microphone is open, and the echo guard
/// follows what is audible. Tap-to-talk capture still holds replies until it finishes.
@MainActor
@Suite struct AmbientDuplexPlaybackTests {
    @Test func repliesPlayImmediatelyWhileAmbientListeningIsOn() async throws {
        let capture = FakeAudioCapture()
        let ambient = AmbientListeningController(
            requestPermission: { true },
            makeStreamer: { send in AmbientAudioStreamer(capture: capture, send: send) },
            releaseSession: {},
            send: { _, _ in }
        )
        let player = DuplexPlayer()
        let playback = ReplyPlaybackController(player: player)
        await ambient.turnOn(for: try binding())
        #expect(ambient.isListening)

        playback.ingest(duplexEvent())
        #expect(player.scheduled.count == 1)
        #expect(!playback.isCaptureSuppressed)
        #expect(playback.statusForControls == "Playing")
        #expect(playback.isReplyAudioOutputBusy)
        #expect(ambient.isOn && ambient.isListening)
        await ambient.turnOff()
    }

    @Test func echoGuardFollowsAudibleReplyPlaybackAndReleasesAfterTheTail() async throws {
        let clock = EchoGuardClock()
        let echoGuard = AmbientReplyEchoGuard(tail: .milliseconds(400), now: { clock.now })
        let player = DuplexPlayer()
        let playback = ReplyPlaybackController(player: player)
        echoGuard.follow(playback)
        echoGuard.follow(playback)
        #expect(!echoGuard.isMasking)

        playback.ingest(duplexEvent())
        try await waitUntil { echoGuard.isMasking }

        player.finish()
        #expect(!playback.isReplyAudioOutputBusy)
        await settle()
        #expect(echoGuard.isMasking)
        clock.advance(by: .milliseconds(400))
        #expect(!echoGuard.isMasking)
    }

    @Test func mutedRepliesAreNotMaskedBecauseNothingIsAudible() async {
        let echoGuard = AmbientReplyEchoGuard(tail: .zero)
        let playback = ReplyPlaybackController(player: DuplexPlayer())
        echoGuard.follow(playback)
        playback.toggleMute()
        playback.ingest(duplexEvent())
        await settle()
        #expect(!playback.isReplyAudioOutputBusy)
        #expect(!echoGuard.isMasking)
    }

    @Test func tapToTalkCaptureStillHoldsReplyPlayback() async {
        let echoGuard = AmbientReplyEchoGuard(tail: .zero)
        let player = DuplexPlayer()
        let playback = ReplyPlaybackController(player: player)
        echoGuard.follow(playback)
        playback.beginCaptureSuppression()

        playback.ingest(duplexEvent())
        await settle()
        #expect(player.scheduled.isEmpty)
        #expect(playback.isCaptureSuppressed)
        #expect(playback.statusForControls == "Paused while listening")
        #expect(!echoGuard.isMasking)

        playback.endCaptureSuppression()
        #expect(player.scheduled.count == 1)
        #expect(playback.statusForControls == "Playing")
    }
}

/// Lets observation-driven Tasks on the main actor run.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private final class DuplexPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    private var onPlayed: (@MainActor @Sendable () -> Void)?

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        if let onPlayed { self.onPlayed = onPlayed }
    }
    func finish() { onPlayed?() }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_: Bool) {}
    func replaceQueue(with _: [AudioPayload], onPlayed _: (@MainActor @Sendable () -> Void)?) {}
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
