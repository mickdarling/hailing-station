import Foundation
import Testing
@testable import HailCore

@Suite("Ambient retirement ownership boundaries", .timeLimit(.minutes(1)))
@MainActor
struct AmbientRetirementOwnershipTests {
    @Test func cancellingAReleaseRequestStillWaitsForOwnedCleanup() async throws {
        let harness = AmbientRetirementHarness()
        defer { harness.unblock() }
        try await harness.start()
        try #require(harness.captures.first).stop()
        try await held(harness.release)
        let closing = Task { await harness.retire(.close) }
        try await joining(harness)
        closing.cancel()
        harness.expectAdmissionHeld()
        harness.release.finish()
        try await finished(harness)
        await closing.value
        #expect(harness.completions == 1)
        #expect(!harness.gate.isClaimed)
    }

    @Test func stopDuringPausedDrainWaitsForBothStreamAndSession() async throws {
        let harness = AmbientRetirementHarness()
        defer { harness.unblock() }
        harness.holdsSends = true
        try await harness.start()
        let capture = try #require(harness.captures.first)
        for offset in [0, 4_800, 9_600] { try capture.yield(sineBuffer(offset: offset)) }
        try await held(harness.sending)
        harness.interruption()
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run { harness.controller.pausedReason != nil && !harness.controller.isListening }
        }
        let stopping = Task { await harness.retire(.stop) }
        try await joining(harness)
        harness.expectAdmissionHeld()
        #expect(!harness.release.isHeld)
        harness.sending.finish()
        try await held(harness.release)
        harness.expectAdmissionHeld()
        harness.release.finish()
        try await finished(harness)
        await stopping.value
        #expect(harness.completions == 1)
        #expect(!harness.gate.isClaimed)
    }

    @Test func closingDuringPermissionKeepsAdmissionUntilTheRequestReturns() async throws {
        let harness = AmbientRetirementHarness()
        defer { harness.unblock() }
        harness.holdsPermission = true
        let starting = Task { try await harness.start() }
        try await held(harness.permission)
        let closing = Task { await harness.retire(.close) }
        try await joining(harness)
        harness.expectAdmissionHeld()
        harness.permission.finish()
        try await finished(harness)
        try await starting.value
        await closing.value
        #expect(harness.captures.isEmpty)
        #expect(!harness.release.isHeld)
        #expect(harness.completions == 1)
        #expect(!harness.gate.isClaimed)
    }

    @Test func anOldRetirementCannotConsumeANewerSessionsCompletion() async throws {
        let harness = AmbientRetirementHarness()
        defer { harness.unblock() }
        try await harness.start()
        let stopping = Task { await harness.controller.turnOff() }
        try await held(harness.release)
        var newerCompletions = 0
        harness.controller.onRetirementCompleted = { newerCompletions += 1 }
        let current = try binding()
        let starting = Task { await harness.controller.turnOn(for: current) }
        try await waitUntil(timeout: .seconds(5)) { await MainActor.run { harness.controller.isOn } }
        harness.release.finish()
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run { harness.completions == 1 && harness.controller.isListening }
        }
        await starting.value
        await stopping.value
        #expect(newerCompletions == 0)
        #expect(harness.controller.onRetirementCompleted != nil)
        await harness.controller.turnOff()
        await harness.controller.waitForRetirement()
        #expect(newerCompletions == 1)
    }

    private func held(_ barrier: AmbientRetirementBarrier) async throws {
        try await waitUntil(timeout: .seconds(5)) { await MainActor.run { barrier.isHeld } }
    }

    private func joining(_ harness: AmbientRetirementHarness) async throws {
        try await waitUntil(timeout: .seconds(5)) { await MainActor.run { harness.requestsJoining == 1 } }
    }

    private func finished(_ harness: AmbientRetirementHarness) async throws {
        try await waitUntil(timeout: .seconds(5)) { await MainActor.run { harness.requestsFinished == 1 } }
    }
}
