import HailCore

actor FakeTranscriber: Transcriber {
    nonisolated let results: AsyncStream<TranscriptionResult>

    private let continuation: AsyncStream<TranscriptionResult>.Continuation
    private(set) var consumedBuffers = 0
    private(set) var isRunning = false

    init() {
        let pair = AsyncStream<TranscriptionResult>.makeStream()
        results = pair.stream
        continuation = pair.continuation
    }

    func start() {
        isRunning = true
    }

    func consume(_: AudioCaptureBuffer) {
        consumedBuffers += 1
    }

    func stop() {
        isRunning = false
    }

    func emit(_ result: TranscriptionResult) {
        continuation.yield(result)
    }
}
