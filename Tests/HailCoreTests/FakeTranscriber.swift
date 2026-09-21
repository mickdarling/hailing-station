import HailCore

actor FakeTranscriber: Transcriber {
    nonisolated let results: AsyncStream<TranscriptionResult>

    private let continuation: AsyncStream<TranscriptionResult>.Continuation
    private(set) var consumedBuffers = 0
    private(set) var isRunning = false
    private var finalText = ""

    init() {
        let pair = AsyncStream<TranscriptionResult>.makeStream()
        results = pair.stream
        continuation = pair.continuation
    }

    func start() {
        isRunning = true
        finalText = ""
    }

    func consume(_: AudioCaptureBuffer) {
        consumedBuffers += 1
    }

    func stop() -> String {
        isRunning = false
        return finalText
    }

    func emit(_ result: TranscriptionResult) {
        if result.isFinal { finalText = result.text }
        continuation.yield(result)
    }
}
