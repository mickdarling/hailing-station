import Foundation
import Testing
@testable import HailCore

/// The round-2 review's suspended-stop/Escape/restart schedule, using the production transcriber.
/// With automatic stop removed, suspend the old append instead; its stale return must leave the new hold intact.
@MainActor
@Suite struct AmbientTapCaptureMaskCleanupRaceTests {
    @Test func oldCleanupCannotReleaseReplacementCapture() async throws {
        let source = FakeAudioCapture()
        let backend = StubStreamingSpeechRecognitionBackend()
        await backend.blockNextAppend()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)
        let clock = EchoGuardClock()
        let echoGuard = AmbientReplyEchoGuard(now: { clock.now })
        let playback = ReplyPlaybackController(player: echoGuard.guarding(DuplexPlayer()))
        let view = TranscriptionLabView(capture: source, playback: playback, transcriber: transcriber)
        await view.begin()
        let oldConsumer = try #require(view.bufferTask)
        try source.yield(sineBuffer())
        await backend.waitUntilAppendIsBlocked()
        source.stop()
        #expect(await backend.endAudioCount == 0)
        // Escape can retire the utterance without joining the already suspended stop caller.
        // That caller no longer exists; the suspended consumer is the only remaining stale completion.
        await view.interruptTarget(using: {})
        await view.begin()
        let replacementID = try #require(view.activeUtteranceID)
        let replacementConsumer = try #require(view.bufferTask)
        #expect(view.isRecording)
        #expect(playback.isCaptureSuppressed)
        await backend.resumeAppend()
        await oldConsumer.value
        try source.yield(sineBuffer())
        try await waitUntil { await backend.appendCount == 1 }
        clock.advance(by: .seconds(1)) // Past the tail: masking must belong to the live replacement.
        #expect(view.isRecording)
        #expect(view.activeUtteranceID == replacementID)
        #expect(view.ownsCaptureSuppression)
        #expect(CapturePlaybackSuppression.reconcile(using: playback) == 0)
        #expect(playback.isCaptureSuppressed)
        #expect(echoGuard.isMasking)
        #expect(CapturePlaybackSuppression.liveness[view.captureOwnerID]?() == true)
        #expect(view.status == "Listening")
        #expect(view.sent.isEmpty)
        #expect(await backend.endAudioCount == 0)
        await cancelAndExpectRelease(replacementConsumer, view: view, clock: clock, echoGuard: echoGuard)
    }

    private func cancelAndExpectRelease(
        _ replacementConsumer: Task<Void, Never>, view: TranscriptionLabView,
        clock: EchoGuardClock, echoGuard: AmbientReplyEchoGuard
    ) async {
        replacementConsumer.cancel()
        await replacementConsumer.value
        #expect(view.isRecording)
        #expect(CapturePlaybackSuppression.reconcile(using: view.playback) == 1)
        #expect(!view.playback.isCaptureSuppressed)
        clock.advance(by: .milliseconds(400))
        #expect(!echoGuard.isMasking)
    }
}
