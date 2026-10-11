import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #445 review round 2: the stream a pause replaced may drain long after. Its late end must still release a
/// session nobody else owns, and its late failures must not touch the live stream.
@MainActor
@Suite struct AmbientInterruptionDrainTests {
    typealias Harness = InterruptionPauseHarness

    @Test func turningOffWhileTheOldStreamDrainsStillReleasesTheSession() async throws {
        let harness = Harness(holdingSends: true)
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        try harness.speak()
        try await waitUntil { await harness.sent.isHolding() }
        harness.interruption(began: true)
        try await harness.waitForBackoff()

        await controller.turnOff()
        #expect(!controller.isOn)
        #expect(harness.releases == 0, "still draining: the session is released once the drain ends")
        await harness.sent.release()
        try await waitUntil { await MainActor.run { harness.releases == 1 } }
        await settle()
        #expect(harness.releases == 1)
    }

    /// Codex P2 (round 4): a transient-refusal recovery already waiting when the interruption arrives must not
    /// renew the replaced stream, clear failure state, or log a start.
    @Test func aRecoveryInFlightAtThePauseNeverRenewsTheOldStream() async throws {
        let suite = "hail-445-recovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:], wallNow: { 1_000 },
                                    clock: { ContinuousClock().now })
        log.setEnabled(true)
        let harness = Harness()
        let controller = harness.controller
        controller.diagnostics = log
        await controller.turnOn(for: try binding())
        harness.refusal = HostConnectionFailure.remote("not_allowed: ambient stopped: idle")
        try harness.speak()
        try await harness.waitForBackoff()

        harness.interruption(began: true)
        try await waitUntil { await MainActor.run { controller.pausedReason != nil } }
        harness.refusal = nil
        // The oldest parked wait is the recovery's: let it finish after the pause.
        await harness.steps.release()
        await settle()
        let starts = try #require(log.nextBatch()).events.filter { $0.name == .ambientStart }
        #expect(starts.count == 1, "only the user's start; no phantom start from the replaced stream")
        #expect(controller.pausedReason != nil)
        #expect(harness.fakes.count == 1)
        await controller.turnOff()
    }

    @Test func theReplacedStreamsLateRefusalDoesNotStopTheResumedOne() async throws {
        let harness = Harness(holdingSends: true)
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        try harness.speak()
        try await waitUntil { await harness.sent.isHolding() }
        harness.interruption(began: true)
        try await harness.waitForBackoff()
        harness.interruption(began: false)
        try await waitUntil { await MainActor.run { controller.isListening } }

        // The old stream's held segment is refused, transiently, when it finally lands: it must not spend the
        // live stream's recoveries (#287), which would park a new backoff wait.
        let waits = await harness.steps.pending
        harness.refusal = HostConnectionFailure.remote("not_allowed: ambient stopped: idle")
        await harness.sent.release()
        await settle()
        #expect(await harness.steps.pending == waits)
        #expect(controller.isOn)
        #expect(controller.isListening)
        #expect(controller.stopReason == nil)
        #expect(controller.handoff == nil)
        harness.refusal = nil
        await controller.turnOff()
    }
}
