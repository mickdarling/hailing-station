import Foundation
import Testing
@testable import HailCore

@Suite("Ambient completed retirement", .timeLimit(.minutes(1)))
@MainActor
struct AmbientRetirementCompletionTests {
    @MainActor private final class ReleaseBarrier {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func finish() { continuation?.resume(); continuation = nil }
    }

    @Test func unexpectedStopReleasesAdmissionOnlyAfterResourceCleanup() async throws {
        let capture = FakeAudioCapture(), barrier = ReleaseBarrier()
        let gate = CoachingCaptureExclusion(), token = UUID()
        let controller = AmbientListeningController(
            requestPermission: { true },
            makeStreamer: { send in AmbientAudioStreamer(capture: capture, send: send) },
            releaseSession: { await barrier.wait() }, send: { _, _ in }
        )
        var completions = 0
        #expect(gate.claim(token))
        controller.onRetirementCompleted = { completions += 1; gate.release(token) }
        await controller.turnOn(for: try binding())
        let stopping = Task { await controller.destinationLost() }
        try await waitUntil { await MainActor.run { barrier.continuation != nil } }
        #expect(!controller.isOn)
        #expect(completions == 0)
        #expect(gate.isClaimed)
        #expect(!gate.claim(UUID()))
        barrier.finish()
        await stopping.value
        #expect(completions == 1)
        #expect(!gate.isClaimed)
        await controller.turnOff()
        #expect(completions == 1)
    }
}
