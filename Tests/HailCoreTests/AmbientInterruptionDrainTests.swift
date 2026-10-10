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
