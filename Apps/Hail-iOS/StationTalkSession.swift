import Foundation
import HailCore
import Observation

/// One microphone, transcriber and result subscription for a station window.
@MainActor @Observable
final class StationTalkSession {
    private(set) var owner: UUID?
    @ObservationIgnored private var receive: (@MainActor (TranscriptionResult) -> Void)?
    @ObservationIgnored private var cleanup: (@MainActor () async -> Void)?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    private var cleanupsInFlight = 0
    private let makeResources: @MainActor () -> TranscriptionResources
    @ObservationIgnored private(set) lazy var resources = makeResources()

    convenience init() {
        self.init {
            TranscriptionResources(capture: AVAudioEngineCapture(), transcriber: StationTalkSession.makeSpeech())
        }
    }

    static func makeSpeech() -> any Transcriber {
        if #available(iOS 26.0, macOS 26.0, *) { return SpeechAnalyzerTranscriber() }
        return SFSpeechRecognizerTranscriber()
    }

    init(makeResources: @escaping @MainActor () -> TranscriptionResources) {
        self.makeResources = makeResources
    }

    deinit { resultsTask?.cancel() }

    func admit(_ id: UUID, receive: @escaping @MainActor (TranscriptionResult) -> Void,
               cleanup: @escaping @MainActor () async -> Void) -> Bool {
        guard owner == nil, cleanupsInFlight == 0 else { return false }
        owner = id
        self.receive = receive
        self.cleanup = cleanup
        if resultsTask == nil {
            let results = resources.transcriber.results
            resultsTask = Task { [weak self] in
                for await result in results { self?.receive?(result) }
            }
        }
        return true
    }

    func retire(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        receive = nil
        cleanup = nil
    }

    func cleanUpScene(deactivateIfNeeded: @MainActor () async -> Void) async {
        cleanupsInFlight += 1
        defer { cleanupsInFlight -= 1 }
        await cleanup?()
        await deactivateIfNeeded()
    }
}
