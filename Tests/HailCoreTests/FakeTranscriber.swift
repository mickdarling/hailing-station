import Foundation
import HailCore

actor FakeTranscriber: Transcriber {
    nonisolated let results: AsyncStream<TranscriptionResult>

    private let continuation: AsyncStream<TranscriptionResult>.Continuation
    private let prepare: (@Sendable () async -> Void)?
    private(set) var consumedBuffers = 0
    private(set) var isRunning = false
    private var finalText = ""
    private var utteranceID = TranscriptionResult.unscopedUtteranceID

    init(prepare: (@Sendable () async -> Void)? = nil) {
        self.prepare = prepare
        let pair = AsyncStream<TranscriptionResult>.makeStream()
        results = pair.stream
        continuation = pair.continuation
    }

    func start() async -> UUID {
        await prepare?()
        isRunning = true
        finalText = ""
        utteranceID = UUID()
        return utteranceID
    }

    func consume(_: AudioCaptureBuffer) {
        consumedBuffers += 1
    }

    func stop() -> String {
        isRunning = false
        return finalText
    }

    func cancel() {
        isRunning = false
        finalText = ""
    }

    func emit(_ result: TranscriptionResult) {
        if result.isFinal { finalText = result.text }
        continuation.yield(
            TranscriptionResult(utteranceID: utteranceID, text: result.text, isFinal: result.isFinal)
        )
    }
}
