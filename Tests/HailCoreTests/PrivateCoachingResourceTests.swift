import Foundation
import Testing
@testable import HailCore

@MainActor
private final class CoachingStartProbe: AudioCapturing {
    var starts = 0
    var stops = 0
    var onStart: () throws -> Void = {}
    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        starts += 1
        try onStart()
        return AsyncStream { _ in }
    }
    func stop() { stops += 1 }
}

/// #269: startup, teardown and resource callbacks cannot revive a retired coaching generation.
@Suite("Private coaching exclusive resources")
@MainActor
struct PrivateCoachingResourceTests {
    @Test func partialCaptureFailureCleansUp() {
        let capture = CoachingStartProbe()
        let player = CoachingTestPlayer()
        var suspended: [CoachingSuspension] = []
        let session = PrivateCoachingSession(
            capture: capture, player: player, observeOutput: { .verifiedHeadphones(UUID()) },
            hooks: .init(buffer: { _, _ in }, suspended: { _, reason in suspended.append(reason) })
        )
        capture.onStart = { throw CoachingSafetyError.invalidAudio }
        #expect(throws: CoachingSafetyError.invalidAudio) {
            try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        }
        #expect(capture.starts == 1 && capture.stops == 1 && player.cancelled == 1)
        #expect(suspended == [.captureFailed] && session.qualification == nil)
    }

    @Test func startingCaptureChangesRouteBeforeFirstAdmission() {
        let capture = CoachingStartProbe()
        let player = CoachingTestPlayer()
        var output = CoachingOutputObservation.verifiedHeadphones(UUID())
        let session = PrivateCoachingSession(
            capture: capture, player: player, observeOutput: { output },
            hooks: .init(buffer: { _, _ in Issue.record("Unsafe buffer admitted") }, suspended: { _, _ in })
        )
        capture.onStart = { output = .unqualified }
        #expect(throws: CoachingSafetyError.unsafeOutput) {
            try session.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        }
        #expect(capture.stops == 1 && player.scheduled.isEmpty && session.qualification == nil)
    }

    @Test func releasingSessionStopsExclusiveResources() throws {
        let capture = CoachingStartProbe()
        let player = CoachingTestPlayer()
        let outputID = UUID()
        var discarded = false
        var session: PrivateCoachingSession? = PrivateCoachingSession(
            capture: capture, player: player, observeOutput: { .verifiedHeadphones(outputID) },
            hooks: .init(buffer: { _, _ in }, suspended: { _, reason in discarded = reason == .stopped }),
            clock: CoachingTestClock().clock
        )
        try session?.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        weak let released = session
        session = nil
        #expect(released == nil)
        #expect(capture.stops == 1 && player.cancelled == 1)
        #expect(discarded) // Downstream provider/context clearing is part of fallback teardown too.
    }

    @Test func synchronousSchedulerInvalidationCannotEnqueueAfterCancellation() throws {
        let rig = CoachingTestHarness()
        try rig.begin()
        let ticket = try rig.ticket()
        rig.time.onSchedule = { rig.session.invalidateRoute() }
        #expect(throws: CoachingSafetyError.staleQualification) {
            try rig.session.schedule(coachingPCM, ticket: ticket)
        }
        #expect(rig.session.qualification == nil && rig.player.scheduled.isEmpty)
        #expect(rig.player.cancelled == 1 && rig.capture.stopCount == 1)
        rig.time.onSchedule = nil
    }

    @Test func sourceCompletionAndResumeFailureSuspend() async throws {
        let rig = CoachingTestHarness()
        try rig.begin()
        rig.capture.stop() // A stream ending unexpectedly suspends, rather than automatically restarting capture.
        await drainCoachingTasks()
        #expect(rig.suspensions == [.captureEnded])
        try rig.begin()
        let ticket = try rig.ticket()
        rig.player.fails = true
        #expect(throws: CoachingSafetyError.invalidAudio) { try rig.session.resume(ticket: ticket) }
        #expect(rig.suspensions.last == .playbackFailed)
    }
}
