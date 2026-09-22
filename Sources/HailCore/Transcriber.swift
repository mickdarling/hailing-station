import AVFAudio
public import Foundation
#if canImport(Speech)
import Speech
#endif

/// A partial or final transcription result (#6).
public struct TranscriptionResult: Sendable, Equatable {
    public static let unscopedUtteranceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public let utteranceID: UUID
    public let text: String
    public let isFinal: Bool

    public init(utteranceID: UUID = unscopedUtteranceID, text: String, isFinal: Bool) {
        self.utteranceID = utteranceID
        self.text = text
        self.isFinal = isFinal
    }
}

/// Turns captured audio into text on the device. SpeechAnalyzer is the first implementation (#6).
public protocol Transcriber: Sendable {
    var results: AsyncStream<TranscriptionResult> { get }
    @discardableResult func start() async throws -> UUID
    func consume(_ buffer: AudioCaptureBuffer) async throws
    /// Finalizes the current utterance and returns the same final text published through `results`.
    /// Returning it closes the race between UI observation and immediate audio-first delivery.
    func stop() async -> String
    /// Stops immediately without finalizing or publishing the current utterance.
    func cancel() async
}

public enum SpeechAnalyzerTranscriberError: LocalizedError, Sendable, Equatable {
    case unavailable
    case unsupportedLocale(String)
    case noCompatibleAudioFormat
    case notRunning
    case conversionFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "On-device transcription is unavailable on this device."
        case .unsupportedLocale(let locale): "On-device transcription does not support \(locale)."
        case .noCompatibleAudioFormat: "No compatible speech-analysis audio format is available."
        case .notRunning: "The transcriber is not running."
        case .conversionFailed: "The microphone audio could not be converted for speech analysis."
        }
    }
}

/// iOS 26's on-device SpeechAnalyzer implementation. It owns model and analysis state, not microphone capture.
@available(iOS 26.0, macOS 26.0, *)
public actor SpeechAnalyzerTranscriber: Transcriber {
    public nonisolated let results: AsyncStream<TranscriptionResult>

    let localeIdentifier: String
    let resultContinuation: AsyncStream<TranscriptionResult>.Continuation
    private var analyzer: SpeechAnalyzer?
    private var analyzerInput: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    var converter: AVAudioConverter?
    private var resultTask: Task<String, Never>?
    private var utteranceID: UUID?
    private var operationGeneration: UInt64 = 0

    public init(localeIdentifier: String = "en-US") {
        self.localeIdentifier = localeIdentifier
        let pair = AsyncStream<TranscriptionResult>.makeStream(bufferingPolicy: .bufferingNewest(32))
        results = pair.stream
        resultContinuation = pair.continuation
    }

    deinit {
        analyzerInput?.finish()
        resultTask?.cancel()
        resultContinuation.finish()
    }

    public func start() async throws -> UUID {
        if analyzer != nil, let utteranceID { return utteranceID }
        operationGeneration &+= 1
        let generation = operationGeneration
        let utteranceID = UUID()
        let (transcriber, format) = try await prepareTranscriber()
        try requireCurrent(generation)
        let modules: [any SpeechModule] = [transcriber]
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(modules: modules)
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try requireCurrent(generation)
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let resultTask = makeResultTask(for: transcriber, utteranceID: utteranceID)

        self.analyzer = analyzer
        self.utteranceID = utteranceID
        self.resultTask = resultTask
        analyzerInput = pair.continuation
        analyzerFormat = format
        converter = nil
        do {
            try await analyzer.start(inputSequence: pair.stream)
            try requireCurrent(generation)
        } catch {
            pair.continuation.finish()
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            if operationGeneration == generation { reset() }
            throw error
        }
        return utteranceID
    }

    public func consume(_ buffer: AudioCaptureBuffer) async throws {
        guard let analyzerInput, let analyzerFormat else {
            throw SpeechAnalyzerTranscriberError.notRunning
        }
        let converted = try convert(buffer.pcmBuffer, to: analyzerFormat)
        analyzerInput.yield(AnalyzerInput(buffer: converted))
    }

    public func stop() async -> String {
        guard let analyzer, let resultTask else { return "" }
        let generation = operationGeneration
        let currentInput = analyzerInput
        currentInput?.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        let text = await resultTask.value
        guard operationGeneration == generation else { return "" }
        operationGeneration &+= 1
        reset()
        return text
    }

    public func cancel() async {
        operationGeneration &+= 1
        let currentAnalyzer = analyzer
        let currentInput = analyzerInput
        let currentResultTask = resultTask
        reset()
        currentInput?.finish()
        currentResultTask?.cancel()
        if let currentAnalyzer { await currentAnalyzer.cancelAndFinishNow() }
    }

    private func requireCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard operationGeneration == generation else { throw CancellationError() }
    }

    private func reset() {
        analyzer = nil
        analyzerInput = nil
        analyzerFormat = nil
        converter = nil
        resultTask = nil
        utteranceID = nil
    }
}
