import Foundation
import Testing
@testable import HailCore

extension SFSpeechRecognizerTranscriber {
    /// Test-only entry fence: the direct same-actor stop call follows this synchronous signal.
    func stopAfterTestEntry(_ entered: AsyncStream<Void>.Continuation) async -> String {
        entered.yield(())
        entered.finish()
        return await stop()
    }
}

func enteredSpeechStop(_ transcriber: SFSpeechRecognizerTranscriber) async -> Task<String, Never> {
    let entered = AsyncStream<Void>.makeStream()
    let stop = Task { await transcriber.stopAfterTestEntry(entered.continuation) }
    _ = await entered.stream.first(where: { _ in true })
    return stop
}

@Suite struct SpeechStopEntryTests {
    @Test func creatingAStopTaskDoesNotGuaranteeItJoinedActiveCleanup() async throws {
        let backend = StubStreamingSpeechRecognitionBackend()
        let transcriber = SFSpeechRecognizerTranscriber(backend: backend)
        _ = try await transcriber.start()
        await backend.blockNextCancel()
        let stopping = await enteredSpeechStop(transcriber)
        await backend.emit(.result(text: "finished", isFinal: true))
        await backend.waitUntilCancelIsBlocked()
        let release = AsyncStream<Void>.makeStream()
        let createdBeforeCleanup = Task {
            _ = await release.stream.first(where: { _ in true })
            return await transcriber.stop()
        }
        await backend.resumeCancel()
        #expect(await stopping.value == "finished")
        release.continuation.yield(())
        release.continuation.finish()
        // A terminal stop is empty; this does not replace any genuinely joined-stop expectation.
        #expect(await createdBeforeCleanup.value == "")
    }
}
