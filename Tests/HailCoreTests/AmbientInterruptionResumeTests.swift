import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #445 review round 1: a resume never takes listening back from another device, a pause keeps the destination,
/// and a backlog held by a slow host cannot leave listening paused with nothing to resume it.
@MainActor
@Suite struct AmbientInterruptionResumeTests {
    typealias Harness = InterruptionPauseHarness

    @Test func theResumedStreamSaysResumeAndYieldsToADeviceThatTookOver() async throws {
        let harness = Harness()
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        try harness.speak()
        try await waitUntil { await !harness.sent.payloads.isEmpty }
        #expect(await harness.sent.payloads.allSatisfy { !$0.isResume })

        harness.interruption(began: true)
        try await harness.waitForBackoff()
        // Someone moved listening to the iPad during the pause: the host refuses the resumed stream.
        harness.refusal = HostConnectionFailure.remote("not_allowed: ambient moved to pad")
        harness.interruption(began: false)
        try await waitUntil { await MainActor.run { controller.isListening } }
        try harness.speak()
        try await waitUntil { await MainActor.run { !controller.isOn } }
        #expect(controller.handoff == .movedAway(to: "pad"))
        #expect(controller.pausedReason == nil)
        #expect(harness.unexpected.isEmpty)
    }

    @Test func aResumedStreamOpensWithResumeOnItsFirstSegmentOnly() async throws {
        let harness = Harness()
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        harness.interruption(began: true)
        try await harness.waitForBackoff()
        harness.interruption(began: false)
        try await waitUntil { await MainActor.run { controller.isListening } }
        try harness.speak()
        try harness.speak()
        try await waitUntil { await harness.sent.payloads.count >= 2 }
        let payloads = await harness.sent.payloads
        #expect(payloads.first?.isResume == true)
        #expect(payloads.first?.sequence == 0)
        #expect(payloads.dropFirst().allSatisfy { !$0.isResume })
        await controller.turnOff()
    }

    /// The flag behind the kept destination (#282) stays true through a pause, so a call or Siri in the
    /// background does not clear the destination and end listening.
    @Test func aPauseKeepsTheDestinationFlagUntilListeningReallyStops() async throws {
        let harness = Harness()
        let controller = harness.controller
        let current = try binding()
        await controller.turnOn(for: current)
        harness.interruption(began: true)
        try await harness.waitForBackoff()
        await controller.update(binding: current, scene: .background)
        #expect(harness.activity == [true])

        harness.interruption(began: false)
        try await waitUntil { await MainActor.run { controller.isListening } }
        #expect(harness.activity == [true])
        await controller.turnOff()
        #expect(harness.activity == [true, false])
    }

    @Test func aBacklogHeldBySlowHostDoesNotBlockTheResume() async throws {
        let harness = Harness(holdingSends: true)
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        try harness.speak()
        try await waitUntil { await harness.sent.isHolding() }

        harness.interruption(began: true)
        // The old stream cannot drain, yet the resumer is already waiting.
        try await harness.waitForBackoff()
        #expect(controller.pausedReason != nil)
        harness.interruption(began: false)
        try await waitUntil { await MainActor.run { controller.isListening } }
        #expect(harness.fakes.count == 2)

        await harness.sent.release()
        await settle()
        // The old stream's late drain neither ends nor releases the resumed session.
        #expect(controller.isListening)
        #expect(harness.releases == 0)
        await controller.turnOff()
    }
}
