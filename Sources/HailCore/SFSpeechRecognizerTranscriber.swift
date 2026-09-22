import AVFAudio
public import Foundation
#if canImport(Speech)
@preconcurrency import Speech
#endif

public enum SFSpeechRecognizerTranscriberError: LocalizedError, Sendable, Equatable {
    case unavailable
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition is unavailable on this device."
        case .notRunning: "The transcriber is not running."
        }
    }
}
/// Short-form streaming transcription for systems before SpeechAnalyzer. The backend prefers Apple's
/// on-device recognizer when the current device and locale support it, and otherwise uses the standard
/// Speech service. Capture remains outside this type so both speech implementations share one audio path.
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
    private var timeoutTask: Task<Void, Never>?
    private var utteranceID: UUID?
    private var startupGeneration: UInt64?
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
        resultContinuation.finish()
    }

    public func start() async throws -> UUID {
        if let utteranceID { return utteranceID }
        guard startupGeneration == nil else { throw CancellationError() }
        operationGeneration &+= 1
        let generation = operationGeneration
        startupGeneration = generation
        let utteranceID = UUID()
        let events = AsyncStream<StreamingSpeechRecognitionEvent>.makeStream(bufferingPolicy: .unbounded)
        let completion = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        eventContinuation = events.continuation
        eventTask = Task { [weak self] in
            for await event in events.stream {
                guard let self else { return }
                await self.receive(event, generation: generation, utteranceID: utteranceID)
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
            try await backend.start(localeIdentifier: localeIdentifier) { event in
                events.continuation.yield(event)
            }
            try requireCurrent(generation: generation, utteranceID: utteranceID)
        } catch {
            // A backend may finish starting after cancel() has already returned. Keep later starts
            // out until this stale startup is torn down, or its cleanup could cancel the new session.
            await backend.cancel()
            if startupGeneration == generation { startupGeneration = nil }
            if operationGeneration == generation, self.utteranceID == utteranceID {
                operationGeneration &+= 1
                complete(with: "")
                reset()
            }
            throw error
        }
        startupGeneration = nil
        return utteranceID
    }

    public func consume(_ buffer: AudioCaptureBuffer) async throws {
        guard utteranceID != nil else { throw SFSpeechRecognizerTranscriberError.notRunning }
        try await backend.append(buffer)
    }

    public func stop() async -> String {
        guard let utteranceID, let completionTask else { return "" }
        let generation = operationGeneration
        await backend.endAudio()
        let timeout = finalizationTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.finishAfterTimeout(generation: generation, utteranceID: utteranceID)
        }
        let text = await completionTask.value
        timeoutTask?.cancel()
        timeoutTask = nil
        guard operationGeneration == generation else { return "" }
        operationGeneration &+= 1
        await backend.cancel()
        reset()
        return text
    }

    public func cancel() async {
        operationGeneration &+= 1
        timeoutTask?.cancel()
        timeoutTask = nil
        complete(with: "")
        reset()
        await backend.cancel()
    }
}

private extension SFSpeechRecognizerTranscriber {
    func receive(
        _ event: StreamingSpeechRecognitionEvent,
        generation: UInt64,
        utteranceID: UUID
    ) {
        guard operationGeneration == generation, self.utteranceID == utteranceID else { return }
        switch event {
        case .result(let text, let isFinal):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { latestText = trimmed }
            resultContinuation.yield(
                TranscriptionResult(utteranceID: utteranceID, text: trimmed, isFinal: isFinal)
            )
            if isFinal { complete(with: latestText) }
        case .failed:
            complete(with: latestText)
        }
    }

    func finishAfterTimeout(generation: UInt64, utteranceID: UUID) {
        guard operationGeneration == generation, self.utteranceID == utteranceID else { return }
        complete(with: latestText)
    }

    func requireCurrent(generation: UInt64, utteranceID: UUID) throws {
        try Task.checkCancellation()
        guard operationGeneration == generation, self.utteranceID == utteranceID else {
            throw CancellationError()
        }
    }

    func complete(with text: String) {
        completionContinuation?.yield(text)
        completionContinuation?.finish()
        completionContinuation = nil
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
        latestText = ""
    }
}
