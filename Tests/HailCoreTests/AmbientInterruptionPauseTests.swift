import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #445: another app taking the microphone pauses ambient listening instead of turning it off; it resumes when the
/// interruption ends, on returning to the foreground, or on a capped backoff, and turning it off cancels all that.
/// Driven through the real capture and its session notifications, with a hand-stepped backoff.
@MainActor
@Suite struct AmbientInterruptionPauseTests {
    typealias Harness = InterruptionPauseHarness

    @Test func anotherAppTakingTheMicPausesWithoutTurningOffThenResumesWhenItEnds() async throws {
        let harness = Harness()
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        #expect(controller.isListening)

        harness.interruption(began: true)
        try await waitUntil { await MainActor.run { controller.pausedReason != nil && harness.releases == 1 } }
        #expect(controller.isOn)
        #expect(!controller.isListening)
        #expect(controller.pausedReason == AmbientListeningController.pausedStatus)
        #expect(controller.stopReason == nil)
        #expect(harness.unexpected.isEmpty)
        #expect(harness.fakes.first?.running == false)

        harness.interruption(began: false)
        try await waitUntil { await MainActor.run { controller.isListening } }
        #expect(controller.pausedReason == nil)
        #expect(harness.fakes.count == 2)
        #expect(harness.fakes.last?.running == true)
        await controller.turnOff()
    }

    @Test func aBusyMicStaysPausedAndTheBackoffRetriesUntilItIsFree() async throws {
        let harness = Harness()
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        harness.interruption(began: true)
        try await harness.waitForBackoff()

        // The other app never says it is done, and still holds the mic at the first retry.
        harness.micBusy = true
        await harness.steps.release()
        try await harness.waitForBackoff()
        #expect(controller.isOn)
        #expect(controller.pausedReason != nil)
        #expect(harness.fakes.count == 1)

        harness.micBusy = false
        await harness.steps.release()
        try await waitUntil { await MainActor.run { controller.isListening } }
        #expect(controller.pausedReason == nil)
        #expect(harness.fakes.count == 2)
        await controller.turnOff()
    }

    @Test func aBusyMicKeepsListeningIntentBeyondTheBackoffSchedule() async throws {
        let harness = Harness()
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        harness.micBusy = true
        harness.interruption(began: true)
        for _ in 0..<(AmbientListeningController.resumeBackoff.count + 3) {
            try await harness.waitForBackoff()
            await harness.steps.release()
        }
        try await harness.waitForBackoff()
        #expect(controller.isOn && !controller.isListening)
        #expect(controller.pausedReason == AmbientListeningController.pausedStatus)
        #expect(controller.stopReason == nil && harness.unexpected.isEmpty)
        #expect(await harness.steps.durations.suffix(3) == [.seconds(60), .seconds(60), .seconds(60)])
        harness.micBusy = false
        await harness.steps.release()
        try await waitUntil { await MainActor.run { controller.isListening } }
        #expect(controller.pausedReason == nil)
        await controller.turnOff()
    }

    @Test func turningOffWhilePausedCancelsEveryResume() async throws {
        let harness = Harness()
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        harness.interruption(began: true)
        try await harness.waitForBackoff()

        await controller.turnOff()
        #expect(!controller.isOn)
        #expect(controller.pausedReason == nil)
        harness.interruption(began: false)
        await harness.steps.release()
        await settle()
        #expect(!controller.isOn)
        #expect(harness.fakes.count == 1)
    }

    @Test func aPauseSurvivesTheBackgroundAndTheForegroundResumes() async throws {
        let harness = Harness()
        let controller = harness.controller
        let current = try binding()
        await controller.turnOn(for: current)
        harness.interruption(began: true)
        try await harness.waitForBackoff()

        await controller.update(binding: current, scene: .inactive)
        await controller.update(binding: current, scene: .background)
        #expect(controller.isOn)
        #expect(controller.pausedReason != nil)

        await controller.update(binding: current, scene: .active)
        #expect(controller.isListening)
        #expect(controller.pausedReason == nil)
        #expect(harness.fakes.count == 2)
        await controller.turnOff()
    }

    @Test func aBindingChangeWhilePausedStillEndsListening() async throws {
        let harness = Harness()
        let controller = harness.controller
        await controller.turnOn(for: try binding())
        harness.interruption(began: true)
        try await harness.waitForBackoff()

        await controller.update(binding: try binding(target: "tmux:other"), scene: .active)
        #expect(!controller.isOn)
        #expect(controller.pausedReason == nil)
    }
}

/// #850: every wait is injected; background deferrals never advance microphone retry pacing or revoke intent.
@MainActor
@Suite struct AmbientInterruptionForegroundRetryTests {
    @Test func backgroundDeferralsKeepTheirRetrySlotAndForegroundResumesWithoutWaiting() async throws {
        let harness = InterruptionPauseHarness()
        let controller = harness.controller
        let current = try binding()
        await controller.turnOn(for: current)
        harness.interruption(began: true)
        try await harness.waitForBackoff()
        await controller.update(binding: current, scene: .background)
        for _ in 0..<(AmbientListeningController.resumeBackoff.count + 3) {
            await harness.steps.release()
            try await waitUntil {
                if await harness.steps.pending > 0 { return true }
                return await MainActor.run { !controller.isOn }
            }
            try #require(controller.isOn)
            #expect(!controller.isListening && harness.fakes.count == 1)
            #expect(controller.pausedReason == AmbientListeningController.foregroundPausedStatus)
        }
        #expect(await harness.steps.durations.allSatisfy { $0 == .seconds(2) })
        #expect(controller.stopReason == nil && harness.unexpected.isEmpty && harness.activity == [true])
        // A real foreground failure may advance pacing, but cannot turn off the owner's listening intent.
        harness.micBusy = true
        await controller.update(binding: current, scene: .active)
        await harness.steps.release()
        try await harness.waitForBackoff()
        #expect(await harness.steps.durations.last == .seconds(5))
        harness.micBusy = false
        await controller.update(binding: current, scene: .active)
        #expect(controller.isOn && controller.isListening && harness.fakes.count == 2)
        #expect(controller.pausedReason == nil && harness.activity == [true])
        await controller.turnOff()
        await harness.steps.release()
    }
}
