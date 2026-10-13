import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
final class CoachingTestPlayer: CoachingAudioPlaying {
    var scheduled: [AudioPayload] = []
    var completions: [@MainActor @Sendable () -> Void] = []
    var cancelled = 0
    var resumed = 0
    var mutes: [Bool] = []
    var fails = false
    var onCancel: (() -> Void)?
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        if fails { throw CoachingSafetyError.invalidAudio }
        scheduled.append(payload)
        if let onPlayed { completions.append(onPlayed) }
    }
    func cancel() { cancelled += 1; onCancel?() }
    func pause() {}
    func resume() throws {
        if fails { throw CoachingSafetyError.invalidAudio }
        resumed += 1
    }
    func setMuted(_ muted: Bool) { mutes.append(muted) }
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        for payload in payloads { try schedule(payload, onPlayed: onPlayed) }
    }
}

@MainActor
final class CoachingTestClock {
    var instant = ContinuousClock.now
    var callbacks: [@MainActor () -> Void] = []
    var clock: CoachingClock {
        CoachingClock(now: { self.instant }, schedule: { _, fire in
            self.callbacks.append(fire)
            return {} // Intentionally deliver stale callbacks to prove revision fences.
        })
    }
    func advance(_ duration: Duration) {
        instant = instant.advanced(by: duration)
        let pending = callbacks
        callbacks.removeAll()
        pending.forEach { $0() }
    }
}

@MainActor
final class CoachingTestHarness {
    let capture = FakeAudioCapture()
    let player = CoachingTestPlayer()
    let time = CoachingTestClock()
    var output = CoachingOutputObservation.verifiedHeadphones(UUID())
    var admitted: [AudioCaptureBuffer] = []
    var suspensions: [CoachingSuspension] = []
    lazy var session = PrivateCoachingSession(
        capture: capture, player: player, observeOutput: { [unowned self] in self.output },
        hooks: .init(buffer: { [unowned self] buffer, _ in self.admitted.append(buffer) },
                     suspended: { [unowned self] _, reason in self.suspensions.append(reason) }), clock: time.clock
    )
    @discardableResult func begin() throws -> CoachingQualification {
        try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
    }
    func ticket() throws -> CoachingAdviceTicket { try session.ticket(requestID: UUID()) }
}

let coachingPCM = AudioPayload(
    codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, isFinal: true, bytes: Data([1, 0, 2, 0])
)

@MainActor
func drainCoachingTasks() async { for _ in 0..<100 { await Task.yield() } }
