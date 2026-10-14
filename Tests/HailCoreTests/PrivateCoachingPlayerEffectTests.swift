import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor private final class CoachingLateEffectPlayer: CoachingAudioPlaying {
    var queued: [AudioPayload] = []
    var active = false
    var cancelled = 0
    var onEffect: () -> Void = {}
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        onEffect(); queued.append(payload); active = true
    }
    func cancel() { cancelled += 1; queued.removeAll(); active = false }
    func pause() { active = false }
    func resume() throws { onEffect(); active = true }
    func setMuted(_ muted: Bool) { onEffect(); active = !muted && !queued.isEmpty }
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        for payload in payloads { try schedule(payload, onPlayed: onPlayed) }
    }
}

@Suite @MainActor struct PrivateCoachingPlayerEffectTests {
    @Test(arguments: [0, 1, 2]) func stopDuringAnEffectCleansLateWorkBeforeFreshAdmission(operation: Int) throws {
        let player = CoachingLateEffectPlayer()
        let capture = FakeAudioCapture()
        let output = UUID()
        let session = PrivateCoachingSession(
            capture: capture, player: player, observeOutput: { .verifiedHeadphones(output) },
            hooks: .init(buffer: { _, _ in }, suspended: { _, _ in }), clock: CoachingTestClock().clock
        )
        try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let ticket = try session.ticket(requestID: UUID())
        player.onEffect = {
            session.stop()
            #expect(throws: CoachingSafetyError.transitionInProgress) {
                try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
            }
        }
        #expect(throws: CoachingSafetyError.staleQualification) {
            if operation == 0 { try session.schedule(coachingPCM, ticket: ticket) }
            if operation == 1 { try session.resume(ticket: ticket) }
            if operation == 2 { try session.setMuted(false, ticket: ticket) }
        }
        #expect(player.queued.isEmpty && !player.active && player.cancelled == 2)
        #expect(session.qualification == nil && capture.stopCount == 1)
        player.onEffect = {}
        try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        try session.schedule(coachingPCM, ticket: session.ticket(requestID: UUID()))
        #expect(player.queued == [coachingPCM] && player.active && session.qualification != nil)
        session.stop()
    }

    @Test func expiryDuringSchedulingCannotLeaveLateAudioQueued() throws {
        let player = CoachingLateEffectPlayer()
        let time = CoachingTestClock()
        let output = UUID()
        let session = PrivateCoachingSession(
            capture: FakeAudioCapture(), player: player, observeOutput: { .verifiedHeadphones(output) },
            hooks: .init(buffer: { _, _ in }, suspended: { _, _ in }), clock: time.clock
        )
        try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let ticket = try session.ticket(requestID: UUID())
        player.onEffect = { time.instant = time.instant.advanced(by: .seconds(3)) }
        #expect(throws: CoachingSafetyError.staleQualification) { try session.schedule(coachingPCM, ticket: ticket) }
        #expect(player.queued.isEmpty && !player.active && session.qualification == nil)
        player.onEffect = {}
    }

    @Test(arguments: [0, 1, 2]) func rawPlayerCannotReplaceDuringALiveEffect(operation: Int) throws {
        let player = CoachingLateEffectPlayer()
        let capture = FakeAudioCapture()
        let output = UUID()
        let session = PrivateCoachingSession(
            capture: capture, player: player, observeOutput: { .verifiedHeadphones(output) },
            hooks: .init(buffer: { _, _ in }, suspended: { _, _ in }), clock: CoachingTestClock().clock
        )
        let live = try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let ticket = try session.ticket(requestID: UUID())
        player.onEffect = {
            #expect(throws: CoachingSafetyError.transitionInProgress) {
                try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
            }
        }
        if operation == 0 { try session.schedule(coachingPCM, ticket: ticket) }
        if operation == 1 { try session.resume(ticket: ticket) }
        if operation == 2 { try session.setMuted(false, ticket: ticket) }
        #expect(session.qualification == live && capture.startCount == 1 && capture.stopCount == 0)
        #expect(player.cancelled == 0)
        player.onEffect = {}
        session.stop()
    }
}
