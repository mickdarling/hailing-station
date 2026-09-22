import Testing
@testable import HailCore

extension SFSpeechRecognizerTranscriberTests {
    @Test func startIsBlockedWhileStopBeginsFinalization() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        await backend.blockNextEndAudio()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)
        _ = try await transcriber.start()

        let stopping = Task { await transcriber.stop() }
        await backend.waitUntilEndAudioIsBlocked()
        await #expect(throws: CancellationError.self) { try await transcriber.start() }
        await backend.emit(.result(text: "finished", isFinal: true))
        await backend.resumeEndAudio()

        #expect(await stopping.value == "finished")
    }

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
}
