import Foundation
@testable import HailCore

actor StubStreamingSpeechRecognitionBackend: StreamingSpeechRecognitionBackend {
    private var handler: (@Sendable (StreamingSpeechRecognitionEvent) -> Void)?
    private var activeUtteranceID: UUID?
    private(set) var startCount = 0
    private(set) var appendCount = 0
    private(set) var endAudioCount = 0
    private(set) var cancelCount = 0
    private var shouldBlockNextStart = false
    private var blockedStartContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextAppend = false
    private var blockedAppendContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextEndAudio = false
    private var blockedEndAudioContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextCancel = false
    private var blockedCancelContinuation: CheckedContinuation<Void, Never>?

    func start(
        utteranceID: UUID,
        localeIdentifier _: String,
        handler: @escaping @Sendable (StreamingSpeechRecognitionEvent) -> Void
    ) async {
        startCount += 1
        if shouldBlockNextStart {
            shouldBlockNextStart = false
            await withCheckedContinuation { blockedStartContinuation = $0 }
        }
        activeUtteranceID = utteranceID
        self.handler = handler
    }

    func append(_: AudioCaptureBuffer, utteranceID: UUID) async throws {
        if shouldBlockNextAppend {
            shouldBlockNextAppend = false
            await withCheckedContinuation { blockedAppendContinuation = $0 }
        }
        guard activeUtteranceID == utteranceID else {
            throw SFSpeechRecognizerTranscriberError.notRunning
        }
        appendCount += 1
    }

    func endAudio(utteranceID: UUID) async {
        endAudioCount += 1
        if shouldBlockNextEndAudio {
            shouldBlockNextEndAudio = false
            await withCheckedContinuation { blockedEndAudioContinuation = $0 }
        }
        guard activeUtteranceID == utteranceID else { return }
    }

    func cancel(utteranceID: UUID) async {
        cancelCount += 1
        if shouldBlockNextCancel {
            shouldBlockNextCancel = false
            await withCheckedContinuation { blockedCancelContinuation = $0 }
        }
        guard activeUtteranceID == utteranceID else { return }
        handler = nil
        activeUtteranceID = nil
    }

    func emit(_ event: StreamingSpeechRecognitionEvent) {
        handler?(event)
    }

    func blockNextStart() {
        shouldBlockNextStart = true
    }

    func waitUntilStartIsBlocked() async {
        while blockedStartContinuation == nil { await Task.yield() }
    }

    func resumeStart() {
        blockedStartContinuation?.resume()
        blockedStartContinuation = nil
    }

    func blockNextAppend() {
        shouldBlockNextAppend = true
    }

    func waitUntilAppendIsBlocked() async {
        while blockedAppendContinuation == nil { await Task.yield() }
    }

    func resumeAppend() {
        blockedAppendContinuation?.resume()
        blockedAppendContinuation = nil
    }

    func blockNextEndAudio() {
        shouldBlockNextEndAudio = true
    }

    func waitUntilEndAudioIsBlocked() async {
        while blockedEndAudioContinuation == nil { await Task.yield() }
    }

    func resumeEndAudio() {
        blockedEndAudioContinuation?.resume()
        blockedEndAudioContinuation = nil
    }

    func blockNextCancel() {
        shouldBlockNextCancel = true
    }

    func waitUntilCancelIsBlocked() async {
        while blockedCancelContinuation == nil { await Task.yield() }
    }

    func resumeCancel() {
        blockedCancelContinuation?.resume()
        blockedCancelContinuation = nil
    }
}
