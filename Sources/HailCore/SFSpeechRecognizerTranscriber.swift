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
    private var completionContinuation: AsyncStream<String>.Continuation?
    private var completionTask: Task<String, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var utteranceID: UUID?
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
        completionTask?.cancel()
        completionContinuation?.finish()
        resultContinuation.finish()
    }

    public func start() async throws -> UUID {
        if let utteranceID { return utteranceID }
        operationGeneration &+= 1
        let generation = operationGeneration
        let utteranceID = UUID()
        let completion = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        completionContinuation = completion.continuation
        completionTask = Task {
            for await text in completion.stream { return text }
            return ""
        }
        latestText = ""
        self.utteranceID = utteranceID
        do {
            try await backend.start(localeIdentifier: localeIdentifier) { [weak self] event in
                Task { await self?.receive(event, generation: generation, utteranceID: utteranceID) }
            }
        } catch {
            complete(with: "")
            reset()
            throw error
        }
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
        await backend.cancel()
        complete(with: "")
        reset()
    }

    private func receive(
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

    private func finishAfterTimeout(generation: UInt64, utteranceID: UUID) {
        guard operationGeneration == generation, self.utteranceID == utteranceID else { return }
        complete(with: latestText)
    }

    private func complete(with text: String) {
        completionContinuation?.yield(text)
        completionContinuation?.finish()
        completionContinuation = nil
    }

    private func reset() {
        timeoutTask?.cancel()
        timeoutTask = nil
        completionTask?.cancel()
        completionTask = nil
        completionContinuation?.finish()
        completionContinuation = nil
        utteranceID = nil
        latestText = ""
    }
}
