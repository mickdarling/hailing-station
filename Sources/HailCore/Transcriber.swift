import AVFAudio
public import Foundation
#if canImport(Speech)
import Speech
#endif

/// A partial or final transcription result (#6).
public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Turns captured audio into text on the device. SpeechAnalyzer is the first implementation (#6).
public protocol Transcriber: Sendable {
    var results: AsyncStream<TranscriptionResult> { get }
    func start() async throws
    func consume(_ buffer: AudioCaptureBuffer) async throws
    func stop() async
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

    private let localeIdentifier: String
    private let resultContinuation: AsyncStream<TranscriptionResult>.Continuation
    private var analyzer: SpeechAnalyzer?
    private var analyzerInput: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultTask: Task<Void, Never>?

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

    public func start() async throws {
        guard analyzer == nil else { return }
        let (transcriber, format) = try await prepareTranscriber()
        let modules: [any SpeechModule] = [transcriber]
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)

        resultTask = Task { [resultContinuation] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    resultContinuation.yield(
                        TranscriptionResult(text: String(result.text.characters), isFinal: result.isFinal)
                    )
                }
            } catch {
                // Feed and setup errors are reported to the caller. Result-stream failures end this utterance.
            }
        }

        self.analyzer = analyzer
        analyzerInput = pair.continuation
        analyzerFormat = format
        converter = nil
        do {
            try await analyzer.start(inputSequence: pair.stream)
        } catch {
            pair.continuation.finish()
            resultTask?.cancel()
            await analyzer.cancelAndFinishNow()
            reset()
            throw error
        }
    }

    private func prepareTranscriber() async throws -> (SpeechTranscriber, AVAudioFormat) {
        guard SpeechTranscriber.isAvailable else { throw SpeechAnalyzerTranscriberError.unavailable }
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw SpeechAnalyzerTranscriberError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let modules: [any SpeechModule] = [transcriber]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw SpeechAnalyzerTranscriberError.noCompatibleAudioFormat
        }
        return (transcriber, format)
    }

    public func consume(_ buffer: AudioCaptureBuffer) async throws {
        guard let analyzerInput, let analyzerFormat else {
            throw SpeechAnalyzerTranscriberError.notRunning
        }
        let converted = try convert(buffer.pcmBuffer, to: analyzerFormat)
        analyzerInput.yield(AnalyzerInput(buffer: converted))
    }

    public func stop() async {
        guard let analyzer else { return }
        analyzerInput?.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        await resultTask?.value
        reset()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { throw SpeechAnalyzerTranscriberError.conversionFailed }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw SpeechAnalyzerTranscriberError.conversionFailed
        }

        let input = ConverterInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !input.wasSupplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            input.wasSupplied = true
            inputStatus.pointee = .haveData
            return input.buffer
        }
        guard status != .error, conversionError == nil else {
            throw SpeechAnalyzerTranscriberError.conversionFailed
        }
        return output
    }

    private func reset() {
        analyzer = nil
        analyzerInput = nil
        analyzerFormat = nil
        converter = nil
        resultTask = nil
    }
}

private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
