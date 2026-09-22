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

    @Test func anEmptyFinalResultRetractsTheLatestPartialText() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)
        var iterator = transcriber.results.makeAsyncIterator()

        let utteranceID = try await transcriber.start()
        await backend.emit(.result(text: "discard this", isFinal: false))
        _ = await iterator.next()
        await backend.emit(.result(text: "   ", isFinal: true))
        let final = await iterator.next()

        #expect(await transcriber.stop() == "")
        #expect(final == TranscriptionResult(utteranceID: utteranceID, text: "", isFinal: true))
    }

    @Test func recognitionFailureFinalizesTheLatestPartialText() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)
        var iterator = transcriber.results.makeAsyncIterator()

        let utteranceID = try await transcriber.start()
        await backend.emit(.result(text: "send this", isFinal: false))
        _ = await iterator.next()
        await backend.emit(.failed)
        let final = await iterator.next()

        #expect(await transcriber.stop() == "send this")
        #expect(final == TranscriptionResult(utteranceID: utteranceID, text: "send this", isFinal: true))
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

    @Test func stopDuringStartupKeepsRestartBlockedUntilStartupCleanup() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        await backend.blockNextStart()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)

        let startup = Task { try await transcriber.start() }
        await backend.waitUntilStartIsBlocked()
        #expect(await transcriber.stop() == "")
        await #expect(throws: CancellationError.self) { try await transcriber.start() }
        await backend.resumeStart()

        await #expect(throws: CancellationError.self) { try await startup.value }
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
}

extension SFSpeechRecognizerTranscriberTests {
    @Test func finalizationTimeoutPublishesTheReturnedFinalText() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        let transcriber = SFSpeechRecognizerTranscriber(
            backend: backend, finalizationTimeout: .milliseconds(1)
        )
        var iterator = transcriber.results.makeAsyncIterator()

        let utteranceID = try await transcriber.start()
        await backend.emit(.result(text: "timed out final", isFinal: false))
        _ = await iterator.next()
        let text = await transcriber.stop()
        let final = await iterator.next()

        #expect(text == "timed out final")
        #expect(final == TranscriptionResult(
            utteranceID: utteranceID, text: "timed out final", isFinal: true
        ))

        let lateResult = Task { await iterator.next() }
        await backend.emit(.result(text: "late recognizer final", isFinal: true))
        await Task.yield()
        lateResult.cancel()
        #expect(await lateResult.value == nil)
    }

    @Test func startWaitsForStopCleanupToFinish() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)
        var iterator = transcriber.results.makeAsyncIterator()
        _ = try await transcriber.start()
        await backend.emit(.result(text: "done", isFinal: true))
        _ = await iterator.next()
        await backend.blockNextCancel()

        let stopping = Task { await transcriber.stop() }
        await backend.waitUntilCancelIsBlocked()
        await #expect(throws: CancellationError.self) { try await transcriber.start() }
        await backend.resumeCancel()

        #expect(await stopping.value == "done")
        _ = try await transcriber.start()
        await transcriber.cancel()
    }

    private func makeCaptureBuffer() throws -> AudioCaptureBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        source.frameLength = 1
        return try #require(AudioCaptureBuffer(copying: source))
    }
}
