import AVFAudio
import Foundation
#if canImport(Speech)
import Speech
#endif

@available(iOS 26.0, macOS 26.0, *)
extension SpeechAnalyzerTranscriber {
    func makeResultTask(for transcriber: SpeechTranscriber, utteranceID: UUID) -> Task<String, Never> {
        Task { [resultContinuation] in
            var finalText = ""
            var volatileText = ""
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return "" }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        if !text.isEmpty {
                            finalText = [finalText, text]
                                .filter { !$0.isEmpty }.joined(separator: " ")
                        }
                        volatileText = ""
                    } else {
                        volatileText = text
                    }
                    resultContinuation.yield(
                        TranscriptionResult(utteranceID: utteranceID, text: text, isFinal: result.isFinal)
                    )
                }
            } catch {
                // Feed and setup errors are reported to the caller. Result-stream failures end this utterance.
            }
            return [finalText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    func prepareTranscriber() async throws -> (SpeechTranscriber, AVAudioFormat) {
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

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
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
}
