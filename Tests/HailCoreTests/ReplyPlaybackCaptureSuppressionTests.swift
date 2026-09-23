import Foundation
import HailCore
import HailProtocol
import Testing

@MainActor
@Suite struct ReplyPlaybackCaptureSuppressionTests {
    @Test func activeReplyPausesForCaptureAndResumesAfterFinalization() {
        let player = CaptureSuppressionPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(captureEvent())

        controller.beginCaptureSuppression()
        #expect(controller.isCaptureSuppressed)
        #expect(controller.statusForControls == "Paused while listening")
        #expect(player.pauseCount == 1)

        controller.endCaptureSuppression()
        #expect(!controller.isCaptureSuppressed)
        #expect(controller.statusForControls == "Playing")
        #expect(player.resumeCount == 1)
    }

    @Test func replyQueuesWithoutSchedulingWhileCaptureIsSuppressed() {
        let player = CaptureSuppressionPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.beginCaptureSuppression()

        controller.ingest(captureEvent())
        #expect(player.scheduled.isEmpty)
        #expect(controller.statusForControls == "Paused while listening")

        controller.endCaptureSuppression()
        #expect(player.scheduled.count == 1)
        #expect(controller.statusForControls == "Playing")
    }

    @Test func explicitPausePreventsAutomaticResumeAfterCapture() {
        let player = CaptureSuppressionPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(captureEvent())
        controller.beginCaptureSuppression()
        controller.togglePause()

        controller.endCaptureSuppression()
        #expect(controller.isPaused)
        #expect(player.resumeCount == 0)
        #expect(controller.statusForControls == "Paused")
    }
}

@MainActor
private final class CaptureSuppressionPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var pauseCount = 0
    var resumeCount = 0

    func schedule(_ payload: AudioPayload, onPlayed _: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
    }
    func cancel() {}
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func setMuted(_: Bool) {}
    func replaceQueue(
        with _: [AudioPayload], onPlayed _: (@MainActor @Sendable () -> Void)?
    ) {}
}

private func captureEvent() -> HostReplyEvent {
    let reply = ReplyDescriptor(
        id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID()
    )
    let audio = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0,
        streamID: reply.audioStreamID, isFinal: true, bytes: Data([1, 0]), reply: reply
    )
    return HostReplyEvent(
        endpointID: "main",
        frame: Frame(timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(audio))
    )
}
