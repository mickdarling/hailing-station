import AVFAudio
import Testing
@testable import HailCore

@Suite struct SFSpeechRecognizerTranscriberTests {
    @Test func streamsPartialAndFinalResultsAndReturnsFinalText() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)
        var iterator = transcriber.results.makeAsyncIterator()

        let utteranceID = try await transcriber.start()
        await backend.emit(.result(text: "hello", isFinal: false))
        let partial = await iterator.next()
        await backend.emit(.result(text: "hello there", isFinal: true))
        let final = await iterator.next()
        let text = await transcriber.stop()

        #expect(partial == TranscriptionResult(utteranceID: utteranceID, text: "hello", isFinal: false))
        #expect(final == TranscriptionResult(utteranceID: utteranceID, text: "hello there", isFinal: true))
        #expect(text == "hello there")
        #expect(await backend.endAudioCount == 1)
        #expect(await backend.cancelCount == 1)
    }

    @Test func recognitionFailureFinalizesTheLatestPartialText() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)

        _ = try await transcriber.start()
        await backend.emit(.result(text: "send this", isFinal: false))
        await backend.emit(.failed)

        #expect(await transcriber.stop() == "send this")
    }

    @Test func cancelDiscardsTheUtteranceAndAllowsAnotherStart() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)

        let first = try await transcriber.start()
        await transcriber.cancel()
        let second = try await transcriber.start()

        #expect(first != second)
        #expect(await backend.startCount == 2)
        #expect(await backend.cancelCount == 1)
        await transcriber.cancel()
    }

    @Test func consumeRequiresAnActiveUtterance() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)
        let buffer = try makeCaptureBuffer()

        await #expect(throws: SFSpeechRecognizerTranscriberError.notRunning) {
            try await transcriber.consume(buffer)
        }
    }

    @Test func cancelDuringStartupCleansUpBeforeAllowingRestart() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        await backend.blockNextStart()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)

        let startup = Task { try await transcriber.start() }
        await backend.waitUntilStartIsBlocked()
        await transcriber.cancel()
        let prematureRestart = Task { try await transcriber.start() }
        await backend.resumeStart()

        await #expect(throws: CancellationError.self) { try await startup.value }
        await #expect(throws: CancellationError.self) { try await prematureRestart.value }
        _ = try await transcriber.start()
        #expect(await backend.cancelCount == 2)
        await transcriber.cancel()
    }

    @Test func canceledStartupTaskCleansUpTheBackend() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        await backend.blockNextStart()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)

        let startup = Task { try await transcriber.start() }
        await backend.waitUntilStartIsBlocked()
        startup.cancel()
        await backend.resumeStart()

        await #expect(throws: CancellationError.self) { try await startup.value }
        #expect(await backend.cancelCount == 1)
        _ = try await transcriber.start()
        await transcriber.cancel()
    }

    @Test func concurrentStartDoesNotExposeAnUnreadyUtterance() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        await backend.blockNextStart()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)

        let startup = Task { try await transcriber.start() }
        await backend.waitUntilStartIsBlocked()
        await #expect(throws: CancellationError.self) { try await transcriber.start() }
        await backend.resumeStart()

        _ = try await startup.value
        await transcriber.cancel()
    }

    private func makeCaptureBuffer() throws -> AudioCaptureBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        source.frameLength = 1
        return try #require(AudioCaptureBuffer(copying: source))
    }
}

private actor StubStreamingSpeechRecognitionBackend: StreamingSpeechRecognitionBackend {
    private var handler: (@Sendable (StreamingSpeechRecognitionEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var endAudioCount = 0
    private(set) var cancelCount = 0
    private var shouldBlockNextStart = false
    private var blockedStartContinuation: CheckedContinuation<Void, Never>?

    func start(
        localeIdentifier _: String,
        handler: @escaping @Sendable (StreamingSpeechRecognitionEvent) -> Void
    ) async {
        startCount += 1
        if shouldBlockNextStart {
            shouldBlockNextStart = false
            await withCheckedContinuation { blockedStartContinuation = $0 }
        }
        self.handler = handler
    }

    func append(_: AudioCaptureBuffer) {}

    func endAudio() {
        endAudioCount += 1
    }

    func cancel() {
        cancelCount += 1
        handler = nil
    }

    func emit(_ event: StreamingSpeechRecognitionEvent) {
        handler?(event)
    }

    func blockNextStart() {
        shouldBlockNextStart = true
    }

    func waitUntilStartIsBlocked() async {
        while blockedStartContinuation == nil { await Task.yield() }
    }

    func resumeStart() {
        blockedStartContinuation?.resume()
        blockedStartContinuation = nil
    }
}
