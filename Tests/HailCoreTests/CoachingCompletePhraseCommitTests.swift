import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor private final class CompletePhraseRig {
    let capture = FakeAudioCapture()
    let time = CoachingTestClock()
    var queued = 0, plays = 0
    var onReady: (() -> Void)?, onSchedule: (() -> Void)?
    func make() throws -> ApplePrivateCoaching {
        let monitor = CoachingOutputMonitor(snapshot: {
            [CoachingObservedPort(uid: "authored-private", kind: .wiredHeadphones)]
        }, center: NotificationCenter(), names: [])
        let player = CoachingEngineRenderer(operations: .init(ready: { [weak self] in
            guard let self else { return false }; onReady?(); return true
        }, schedule: { [weak self] _, _ in self?.queued += 1; self?.onSchedule?() }, control: { [weak self] command in
            if case .play = command { self?.plays += 1 }
            if case .stop = command { self?.queued = 0 }
        }), observe: { monitor.observe() })
        let audio = try ApplePrivateCoaching(capture: capture, player: player, monitor: monitor,
            listenerID: "private-coach", hooks: .init(buffer: { _, _ in }, suspended: { _, _ in }), clock: time.clock)
        return audio
    }
    func phrase(_ bytes: Int) -> [AudioPayload] {
        var remaining = bytes, result: [AudioPayload] = []
        while remaining > 0 {
            let size = min(48_000, remaining); remaining -= size
            result.append(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1,
                sequence: result.count, isFinal: remaining == 0, bytes: Data(repeating: 17, count: size)))
        }
        return result
    }
}

@Suite @MainActor struct CoachingCompletePhraseCommitTests {
    @Test func completePhraseQueuesEveryBufferBeforeTheFirstNativePlay() throws {
        let rig = CompletePhraseRig(), audio = try rig.make()
        let lease = try audio.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try audio.prepareSpeech(audio.admit(coachingWireData(lease)))
        rig.onSchedule = { #expect(rig.plays == 0) }
        try audio.playCompletePhrase(rig.phrase(134_144), for: advice)
        #expect(rig.queued == 3 && rig.plays == 1 && audio.privatePlaybackObservation() == .pending)
        rig.onSchedule = nil; audio.stop()
        #expect(rig.queued == 0 && rig.capture.stopCount == 1)
    }

    @Test func slowNativeReadinessCannotStartPhraseWhichNoLongerFits() throws {
        let rig = CompletePhraseRig(), audio = try rig.make()
        var lease = try audio.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try audio.prepareSpeech(audio.admit(coachingWireData(lease)))
        for _ in 0..<16 { rig.time.advance(.seconds(1)); lease = try audio.renew(lease) }
        rig.time.instant = rig.time.instant.advanced(by: .milliseconds(900))
        rig.onReady = {
            rig.onReady = nil
            rig.time.instant = rig.time.instant.advanced(by: .milliseconds(200))
        }
        #expect(throws: CoachingSpeechFailure.durationExceeded) {
            try audio.playCompletePhrase(rig.phrase(48_000), for: advice)
        }
        #expect(rig.plays == 0 && rig.queued == 0 && rig.capture.stopCount == 0)
        #expect(audio.privatePlaybackObservation() == .idle)
        let fresh = try audio.prepareSpeech(audio.admit(coachingWireData(lease)))
        try audio.playCompletePhrase(rig.phrase(480), for: fresh)
        #expect(rig.plays == 1 && rig.capture.startCount == 1)
        audio.stop()
    }

    @Test func slowQueueingStillRechecksWholeDurationAtActualFirstPlay() throws {
        let rig = CompletePhraseRig(), audio = try rig.make()
        var lease = try audio.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try audio.prepareSpeech(audio.admit(coachingWireData(lease)))
        for _ in 0..<14 { rig.time.advance(.seconds(1)); lease = try audio.renew(lease) }
        rig.time.instant = rig.time.instant.advanced(by: .milliseconds(900))
        rig.onSchedule = {
            #expect(rig.plays == 0)
            if rig.queued == 3 { rig.time.instant = rig.time.instant.advanced(by: .milliseconds(200)) }
        }
        #expect(throws: CoachingSpeechFailure.durationExceeded) {
            try audio.playCompletePhrase(rig.phrase(144_000), for: advice)
        }
        #expect(rig.plays == 0 && rig.queued == 0 && rig.capture.stopCount == 0)
        rig.onSchedule = nil; audio.stop()
    }

    @Test func revocationInsideNativeReadinessCannotPlayOldBatch() throws {
        let rig = CompletePhraseRig(), audio = try rig.make()
        let lease = try audio.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try audio.prepareSpeech(audio.admit(coachingWireData(lease)))
        rig.onReady = { rig.onReady = nil; audio.interruptSpeech() }
        #expect(throws: (any Error).self) { try audio.playCompletePhrase(rig.phrase(48_000), for: advice) }
        #expect(rig.plays == 0 && rig.queued == 0 && rig.capture.stopCount == 0)
        rig.onSchedule = nil; audio.stop()
    }

    @Test func malformedOrOversizedBatchFailsBeforeNativeEffects() throws {
        let rig = CompletePhraseRig(), audio = try rig.make()
        let lease = try audio.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try audio.prepareSpeech(audio.admit(coachingWireData(lease)))
        var wrong = rig.phrase(480); wrong[0].isFinal = false
        for phrase in [[], wrong, rig.phrase(CoachingSpeechBudget.pcmBytes + 2)] {
            #expect(throws: (any Error).self) { try audio.playCompletePhrase(phrase, for: advice) }
        }
        #expect(rig.plays == 0 && rig.queued == 0 && rig.capture.stopCount == 0)
        rig.onSchedule = nil; audio.stop()
    }
}
