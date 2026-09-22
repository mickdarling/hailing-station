public import Foundation
#if canImport(Speech)
@preconcurrency import Speech
#endif

public enum SFSpeechRecognizerTranscriberError: LocalizedError, Sendable, Equatable {
    case unavailable
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .unavailable: "On-device speech recognition is unavailable for this language."
        case .notRunning: "The transcriber is not running."
        }
    }
}

enum StreamingSpeechRecognitionEvent: Sendable, Equatable {
    case result(text: String, isFinal: Bool)
    case failed
}

protocol StreamingSpeechRecognitionBackend: Sendable {
    func start(
        utteranceID: UUID,
        localeIdentifier: String,
        handler: @escaping @Sendable (StreamingSpeechRecognitionEvent) -> Void
    ) async throws
    func append(_ buffer: AudioCaptureBuffer, utteranceID: UUID) async throws
    func endAudio(utteranceID: UUID) async
    func cancel(utteranceID: UUID) async
}

#if canImport(Speech)
actor AppleStreamingSpeechRecognitionBackend: StreamingSpeechRecognitionBackend {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var activeUtteranceID: UUID?

    func start(
        utteranceID: UUID,
        localeIdentifier: String,
        handler: @escaping @Sendable (StreamingSpeechRecognitionEvent) -> Void
    ) throws {
        guard task == nil,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw SFSpeechRecognizerTranscriberError.unavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        activeUtteranceID = utteranceID
        self.recognizer = recognizer
        self.request = request
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                handler(.result(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                ))
            }
            if error != nil, result?.isFinal != true { handler(.failed) }
        }
    }

    func append(_ buffer: AudioCaptureBuffer, utteranceID: UUID) throws {
        guard activeUtteranceID == utteranceID, let request else {
            throw SFSpeechRecognizerTranscriberError.notRunning
        }
        request.append(buffer.pcmBuffer)
    }

    func endAudio(utteranceID: UUID) {
        guard activeUtteranceID == utteranceID else { return }
        request?.endAudio()
    }

    func cancel(utteranceID: UUID) {
        guard activeUtteranceID == utteranceID else { return }
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        activeUtteranceID = nil
    }
}
#endif
