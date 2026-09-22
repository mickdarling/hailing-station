public import Foundation
public actor SFSpeechRecognizerTranscriber: Transcriber {
    public nonisolated let results: AsyncStream<TranscriptionResult>
    private let localeIdentifier: String
    private let backend: any StreamingSpeechRecognitionBackend
    private let finalizationTimeout: Duration
    private let resultContinuation: AsyncStream<TranscriptionResult>.Continuation
    private var eventContinuation: AsyncStream<StreamingSpeechRecognitionEvent>.Continuation?
    private var eventTask: Task<Void, Never>?
    private var completionContinuation: AsyncStream<String>.Continuation?
    private var completionTask: Task<String, Never>?
    private var stopCleanupContinuation: AsyncStream<String>.Continuation?
    private var stopCleanupTask: Task<String, Never>?
    private var stopCleanupGeneration: UInt64?
    private var timeoutTask: Task<Void, Never>?
    private var utteranceID: UUID?
    private var backendTransitionGeneration: UInt64?
    private var didFinalize = false
    private var latestText = ""
    private var operationGeneration: UInt64 = 0
    public init(localeIdentifier: String = "en-US") {
        self.localeIdentifier = localeIdentifier
        backend = AppleStreamingSpeechRecognitionBackend()
        finalizationTimeout = .seconds(3)
        let pair = AsyncStream<TranscriptionResult>.makeStream(bufferingPolicy: .bufferingNewest(32))
        results = pair.stream
        resultContinuation = pair.continuation
    }
    init(
        localeIdentifier: String = "en-US",
        backend: any StreamingSpeechRecognitionBackend,
        finalizationTimeout: Duration = .seconds(3)
    ) {
        self.localeIdentifier = localeIdentifier
        self.backend = backend
        self.finalizationTimeout = finalizationTimeout
        let pair = AsyncStream<TranscriptionResult>.makeStream(bufferingPolicy: .bufferingNewest(32))
        results = pair.stream
        resultContinuation = pair.continuation
    }
    deinit {
        timeoutTask?.cancel()
        eventTask?.cancel()
        eventContinuation?.finish()
        completionTask?.cancel()
        completionContinuation?.finish()
        stopCleanupTask?.cancel()
        stopCleanupContinuation?.finish()
        resultContinuation.finish()
    }
    public func start() async throws -> UUID {
        guard backendTransitionGeneration == nil else { throw CancellationError() }
        if let utteranceID { return utteranceID }
        operationGeneration &+= 1
        let generation = operationGeneration
        backendTransitionGeneration = generation
        let utteranceID = UUID()
        let events = AsyncStream<StreamingSpeechRecognitionEvent>.makeStream(bufferingPolicy: .unbounded)
        let completion = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        eventContinuation = events.continuation
        eventTask = Task { [weak self] in
            for await event in events.stream {
                if let self { await self.receive(event, generation: generation, utteranceID: utteranceID) }
            }
        }
        completionContinuation = completion.continuation
        completionTask = Task {
            for await text in completion.stream { return text }
            return ""
        }
        latestText = ""
        self.utteranceID = utteranceID
        do {
            try await backend.start(localeIdentifier: localeIdentifier) { events.continuation.yield($0) }
            try requireCurrent(generation: generation, utteranceID: utteranceID)
        } catch {
            await backend.cancel()
            if backendTransitionGeneration == generation { backendTransitionGeneration = nil }
            if operationGeneration == generation, self.utteranceID == utteranceID {
                operationGeneration &+= 1
                complete(with: "")
                reset()
            }
            throw error
        }
        backendTransitionGeneration = nil
        return utteranceID
    }
    public func consume(_ buffer: AudioCaptureBuffer) async throws {
        guard utteranceID != nil else { throw SFSpeechRecognizerTranscriberError.notRunning }
        try await backend.append(buffer)
    }
    public func stop() async -> String {
        if let stopCleanupTask { return await stopCleanupTask.value }
        guard let utteranceID, let completionTask else { return "" }
        if backendTransitionGeneration == operationGeneration {
            await cancel()
            return ""
        }
        let generation = operationGeneration
        stopCleanupGeneration = generation
        let cleanup = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stopCleanupContinuation = cleanup.continuation
        let cleanupTask = Task { await cleanup.stream.first(where: { _ in true }) ?? "" }
        stopCleanupTask = cleanupTask
        backendTransitionGeneration = generation
        let timeout = finalizationTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.finishAfterTimeout(generation: generation, utteranceID: utteranceID)
        }
        await backend.endAudio()
        let text = await completionTask.value
        timeoutTask?.cancel()
        timeoutTask = nil
        guard operationGeneration == generation else { return await cleanupTask.value }
        operationGeneration &+= 1
        reset()
        await backend.cancel()
        guard operationGeneration == generation &+ 1 else { return await cleanupTask.value }
        if backendTransitionGeneration == generation { backendTransitionGeneration = nil }
        if stopCleanupGeneration == generation { completeStopCleanup(with: text) }
        return text
    }
    public func cancel() async {
        let stoppingGeneration = stopCleanupGeneration
        operationGeneration &+= 1
        let cancellationGeneration = operationGeneration
        if backendTransitionGeneration == nil { backendTransitionGeneration = cancellationGeneration }
        timeoutTask?.cancel()
        timeoutTask = nil
        complete(with: "")
        reset()
        await backend.cancel()
        if [cancellationGeneration, stoppingGeneration].contains(backendTransitionGeneration) {
            backendTransitionGeneration = nil
        }
        if let stoppingGeneration, stopCleanupGeneration == stoppingGeneration {
            completeStopCleanup(with: "")
        }
    }
}
private extension SFSpeechRecognizerTranscriber {
    func receive(_ event: StreamingSpeechRecognitionEvent, generation: UInt64, utteranceID: UUID) {
        guard operationGeneration == generation, self.utteranceID == utteranceID,
              !didFinalize else { return }
        switch event {
        case .result(let text, let isFinal):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isFinal || !trimmed.isEmpty { latestText = trimmed }
            if isFinal { didFinalize = true }
            resultContinuation.yield(TranscriptionResult(utteranceID: utteranceID, text: trimmed, isFinal: isFinal))
            if isFinal { complete(with: latestText) }
        case .failed:
            publishFinal(utteranceID: utteranceID)
        }
    }
    func finishAfterTimeout(generation: UInt64, utteranceID: UUID) {
        guard operationGeneration == generation, self.utteranceID == utteranceID else { return }
        publishFinal(utteranceID: utteranceID)
    }
    func publishFinal(utteranceID: UUID) {
        guard !didFinalize else { return }
        didFinalize = true
        resultContinuation.yield(TranscriptionResult(utteranceID: utteranceID, text: latestText, isFinal: true))
        complete(with: latestText)
    }
    func requireCurrent(generation: UInt64, utteranceID: UUID) throws {
        try Task.checkCancellation()
        guard operationGeneration == generation, self.utteranceID == utteranceID else { throw CancellationError() }
    }
    func complete(with text: String) {
        completionContinuation?.yield(text)
        completionContinuation?.finish()
        completionContinuation = nil
    }
    func completeStopCleanup(with text: String) {
        stopCleanupContinuation?.yield(text)
        stopCleanupContinuation?.finish()
        stopCleanupContinuation = nil
        stopCleanupTask = nil
        stopCleanupGeneration = nil
    }
    func reset() {
        timeoutTask?.cancel()
        timeoutTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        completionTask?.cancel()
        completionTask = nil
        completionContinuation?.finish()
        completionContinuation = nil
        utteranceID = nil
        didFinalize = false
        latestText = ""
    }
}
