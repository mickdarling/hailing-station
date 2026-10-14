import Foundation
import Testing
@testable import HailCore

@Suite("Ambient admission joins all owned retirement", .timeLimit(.minutes(1)))
@MainActor
struct AmbientRetirementJoinTests {
    @Test(arguments: [AmbientRetirementAction.close, .update])
    func anUnexpectedEndKeepsAdmissionThroughConcurrentRequests(_ action: AmbientRetirementAction) async throws {
        let harness = AmbientRetirementHarness()
        defer { harness.unblock() }
        try await harness.start()
        try #require(harness.captures.first).stop()
        try await held(harness.release)
        #expect(!harness.controller.isOn)
        let closing = Task { await harness.retire(action) }
        try await parkedRequest(harness)
        harness.expectAdmissionHeld()
        harness.release.finish()
        try await finished(harness)
        await closing.value
        #expect(harness.completions == 1)
        #expect(!harness.gate.isClaimed)
    }

    @Test(arguments: [AmbientRetirementAction.stop, .close])
    func aPausedReleaseKeepsAdmissionThroughConcurrentRequests(_ action: AmbientRetirementAction) async throws {
        let harness = AmbientRetirementHarness()
        defer { harness.unblock() }
        try await harness.start()
        harness.interruption()
        try await held(harness.release)
        #expect(harness.controller.pausedReason != nil)
        #expect(!harness.controller.isListening)
        let stopping = Task { await harness.retire(action) }
        try await parkedRequest(harness)
        harness.expectAdmissionHeld()
        harness.release.finish()
        try await finished(harness)
        await stopping.value
        #expect(harness.completions == 1)
        #expect(!harness.gate.isClaimed)
    }

    @Test(arguments: [AmbientRetirementAction.stop, .close])
    func aPendingFactoryMustReturnAndReleaseBeforeAdmission(_ action: AmbientRetirementAction) async throws {
        let harness = AmbientRetirementHarness()
        defer { harness.unblock() }
        harness.holdsFactory = true
        let starting = Task { try await harness.start() }
        try await held(harness.factory)
        let stopping = Task { await harness.retire(action) }
        try await parkedRequest(harness)
        harness.expectAdmissionHeld()
        harness.factory.finish()
        try await held(harness.release)
        harness.expectAdmissionHeld()
        harness.release.finish()
        try await finished(harness)
        try await starting.value
        await stopping.value
        #expect(harness.captures.map(\.startCount) == [0])
        #expect(harness.completions == 1)
        #expect(!harness.gate.isClaimed)
    }

    @Test func aResumingFactoryStillOwnsAdmissionAfterStop() async throws {
        let harness = AmbientRetirementHarness()
        defer { harness.unblock() }
        try await harness.start()
        let current = try #require(harness.controller.binding)
        harness.interruption()
        try await held(harness.release)
        harness.release.finish()
        harness.holdsFactory = true
        let resuming = Task { await harness.controller.update(binding: current, scene: .active) }
        try await held(harness.factory)
        let stopping = Task { await harness.retire(.stop) }
        try await parkedRequest(harness)
        harness.expectAdmissionHeld()
        harness.factory.finish()
        try await finished(harness)
        await resuming.value
        await stopping.value
        #expect(harness.captures.map(\.startCount) == [1, 0])
        #expect(harness.completions == 1)
        #expect(!harness.gate.isClaimed)
    }

    private func held(_ barrier: AmbientRetirementBarrier) async throws {
        try await waitUntil(timeout: .seconds(5)) { await MainActor.run { barrier.isHeld } }
    }

    private func parkedRequest(_ harness: AmbientRetirementHarness) async throws {
        try await waitUntil(timeout: .seconds(5)) { await MainActor.run { harness.requestsJoining == 1 } }
        #expect(!harness.controller.isOn)
    }

    private func finished(_ harness: AmbientRetirementHarness) async throws {
        try await waitUntil(timeout: .seconds(5)) { await MainActor.run { harness.requestsFinished == 1 } }
    }
}
