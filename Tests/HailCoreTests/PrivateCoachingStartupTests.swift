import Foundation
import Testing
@testable import HailCore

@MainActor private final class CoachingLateStartProbe: AudioCapturing {
    var starts = 0
    var stops = 0
    var active = false
    var onStart: () throws -> Void = {}
    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        starts += 1
        try onStart()
        active = true // Model a resource effect that finishes after a synchronous Stop callback.
        return AsyncStream { _ in }
    }
    func stop() { stops += 1; active = false }
}

@Suite @MainActor struct PrivateCoachingStartupTests {
    @Test(arguments: [false, true]) func cancellationDuringInitialObservationPreventsCapture(route: Bool) {
        let capture = CoachingLateStartProbe()
        let output = UUID()
        var cancel: () -> Void = {}
        let session = PrivateCoachingSession(
            capture: capture, player: CoachingTestPlayer(), observeOutput: {
                let callback = cancel; cancel = {}; callback()
                return .verifiedHeadphones(output)
            }, hooks: .init(buffer: { _, _ in Issue.record("cancelled capture admitted a buffer") },
                            suspended: { _, _ in }), clock: CoachingTestClock().clock
        )
        cancel = { if route { session.invalidateRoute() } else { session.stop() } }
        #expect(throws: CoachingSafetyError.staleQualification) {
            try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        }
        #expect(capture.starts == 0 && !capture.active && session.qualification == nil)
    }

    @Test(arguments: [false, true]) func cancellationDuringInitialClockReadPreventsCapture(route: Bool) {
        let capture = CoachingLateStartProbe()
        let time = CoachingTestClock()
        let output = UUID()
        let session = PrivateCoachingSession(
            capture: capture, player: CoachingTestPlayer(), observeOutput: { .verifiedHeadphones(output) },
            hooks: .init(buffer: { _, _ in }, suspended: { _, _ in }), clock: time.clock
        )
        time.onNow = {
            time.onNow = nil
            if route { session.invalidateRoute() } else { session.stop() }
        }
        #expect(throws: CoachingSafetyError.staleQualification) {
            try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        }
        #expect(capture.starts == 0 && !capture.active && session.qualification == nil)
    }

    @Test(arguments: [false, true]) func cancellationDuringStartCleansUpItsLateResourceEffect(route: Bool) {
        let capture = CoachingLateStartProbe()
        let output = UUID()
        let player = CoachingTestPlayer()
        let session = PrivateCoachingSession(
            capture: capture, player: player, observeOutput: { .verifiedHeadphones(output) },
            hooks: .init(buffer: { _, _ in }, suspended: { _, _ in }), clock: CoachingTestClock().clock
        )
        capture.onStart = { if route { session.invalidateRoute() } else { session.stop() } }
        #expect(throws: CoachingSafetyError.staleQualification) {
            try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        }
        #expect(capture.starts == 1 && capture.stops == 2 && !capture.active)
        #expect(session.qualification == nil && player.scheduled.isEmpty)
        capture.onStart = {}
    }

    @Test func cancellationDuringPriorResourceRetirementPreventsReplacementCapture() throws {
        let rig = CoachingTestHarness()
        try rig.begin()
        rig.player.onCancel = { rig.player.onCancel = nil; rig.session.stop() }
        #expect(throws: CoachingSafetyError.staleQualification) { try rig.begin() }
        #expect(rig.capture.startCount == 1 && rig.capture.stopCount == 1 && rig.session.qualification == nil)
    }
}
