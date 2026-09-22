import Foundation
#if canImport(Speech)
@preconcurrency import Speech
#endif

enum StreamingSpeechRecognitionEvent: Sendable, Equatable {
    case result(text: String, isFinal: Bool)
    case failed
}

protocol StreamingSpeechRecognitionBackend: Sendable {
    func start(
        localeIdentifier: String,
        handler: @escaping @Sendable (StreamingSpeechRecognitionEvent) -> Void
    ) async throws
    func append(_ buffer: AudioCaptureBuffer) async throws
    func endAudio() async
    func cancel() async
}

#if canImport(Speech)
actor AppleStreamingSpeechRecognitionBackend: StreamingSpeechRecognitionBackend {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(
        localeIdentifier: String,
        handler: @escaping @Sendable (StreamingSpeechRecognitionEvent) -> Void
    ) throws {
        guard task == nil,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw SFSpeechRecognizerTranscriberError.unavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
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

    func append(_ buffer: AudioCaptureBuffer) throws {
        guard let request else { throw SFSpeechRecognizerTranscriberError.notRunning }
        request.append(buffer.pcmBuffer)
    }

    func endAudio() {
        request?.endAudio()
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }
}
#endif
