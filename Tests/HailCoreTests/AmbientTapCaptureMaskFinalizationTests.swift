import Foundation
import Testing
@testable import HailCore

// Actual production SpeechAnalyzerTranscriber.stop body below, unchanged. Only analyzer IO and result
// production are synthetic. This probes two normally completing finalizations without Apple speech/TCC.
actor ReviewSyntheticAnalyzer {
    var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var finalizations = 0
    func finalizeAndFinishThroughEndOfInput() async throws {
        finalizations += 1
        let index = finalizations
        await withCheckedContinuation { waiters[index] = $0 }
    }
    func cancelAndFinishNow() {}
    func release(_ index: Int) { waiters.removeValue(forKey: index)?.resume() }
}

actor ReviewAnalyzerStopTranscriber: Transcriber {
    nonisolated let results = AsyncStream<TranscriptionResult> { $0.finish() }
    private let synthetic: ReviewSyntheticAnalyzer
    private var analyzer: ReviewSyntheticAnalyzer?
    private var resultTask: Task<String, Never>?
    private var analyzerInput: AsyncStream<Int>.Continuation?
    private var operationGeneration: UInt64 = 0
    init(_ analyzer: ReviewSyntheticAnalyzer) { synthetic = analyzer }
    func start() -> UUID {
        operationGeneration &+= 1
        analyzer = synthetic
        resultTask = Task { "review request" }
        return UUID()
    }
    func consume(_ buffer: AudioCaptureBuffer) {}
    public func stop() async -> String {
        guard let analyzer, let resultTask else { return "" }
        let generation = operationGeneration
        let currentInput = analyzerInput
        currentInput?.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        let text = await resultTask.value
        guard operationGeneration == generation else { return "" }
        operationGeneration &+= 1
        reset()
        return text
    }

    func cancel() { operationGeneration &+= 1; reset() }
    private func reset() { analyzer = nil; resultTask = nil; analyzerInput = nil }
}

/// Round-3 reproduction: stream termination must never compete with the user's explicit Finish.
@MainActor
@Suite struct AmbientTapCaptureMaskFinalizationTests {
    @Test func normalEndThenFinishFinalizesAnalyzerExactlyOnce() async throws {
        let source = FakeAudioCapture()
        let analyzer = ReviewSyntheticAnalyzer()
        let transcriber = ReviewAnalyzerStopTranscriber(analyzer)
        let playback = ReplyPlaybackController(player: AmbientReplyEchoGuard().guarding(DuplexPlayer()))
        let view = TranscriptionLabView(capture: source, playback: playback, transcriber: transcriber)
        view.onFinalized = { _ in }
        await view.begin()
        let consumer = try #require(view.bufferTask)
        source.stop()
        await consumer.value
        #expect(await analyzer.finalizations == 0)
        #expect(view.isRecording) // UI still offers Tap to finish, with Finish/Escape enabled.
        #expect(view.sent.isEmpty)
        #expect(CapturePlaybackSuppression.reconcile(using: playback) == 1)
        let finish = Task { await view.finish() }
        try await waitUntil { await analyzer.finalizations == 1 }
        let joinedFinish = Task { await view.finish() }
        await settle()
        await analyzer.release(1)
        await finish.value
        await joinedFinish.value
        await view.finish()
        #expect(await analyzer.finalizations == 1)
        #expect(view.sent == ["review request"])
        #expect(!playback.isCaptureSuppressed)
        #expect(!view.isRecording)
    }

    @Test func normalEndThenFinishFinalizesFallbackExactlyOnce() async throws {
        let source = FakeAudioCapture()
        let backend = StubStreamingSpeechRecognitionBackend()
        await backend.blockNextEndAudio()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)
        let playback = ReplyPlaybackController(player: AmbientReplyEchoGuard().guarding(DuplexPlayer()))
        let view = TranscriptionLabView(capture: source, playback: playback, transcriber: transcriber)
        view.onFinalized = { _ in }
        await view.begin()
        let consumer = try #require(view.bufferTask)
        source.stop()
        await consumer.value
        #expect(await backend.endAudioCount == 0)
        #expect(view.isRecording)
        #expect(view.sent.isEmpty)
        #expect(CapturePlaybackSuppression.reconcile(using: playback) == 1)
        let finish = Task { await view.finish() }
        await backend.waitUntilEndAudioIsBlocked()
        await backend.emit(.result(text: "review request", isFinal: true))
        await backend.resumeEndAudio()
        await finish.value
        await view.finish()
        #expect(await backend.endAudioCount == 1)
        #expect(view.sent == ["review request"])
        #expect(!playback.isCaptureSuppressed)
        #expect(!view.isRecording)
    }
}
