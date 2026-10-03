import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// The "Ambient listening" toggle (#203 PR 5): off by default, foreground-only, bound to one destination, and
/// never restarted by itself.
@MainActor
@Suite struct AmbientListeningControllerTests {
    @MainActor
    final class Harness {
        let capture = FakeAudioCapture()
        var permission = true
        var released = 0
        var sendError: (any Error)?
        var sent: [AudioPayload] = []
        lazy var controller = AmbientListeningController(
            requestPermission: { [unowned self] in permission },
            makeStreamer: { [unowned self] send in AmbientAudioStreamer(capture: capture, send: send) },
            releaseSession: { [unowned self] in released += 1 },
            send: { [unowned self] payload, _ in try await record(payload) }
        )

        func record(_ payload: AudioPayload) throws {
            if let sendError { throw sendError }
            sent.append(payload)
        }
    }

    @Test func startsOffAndListensOnlyAfterTheUserTurnsItOn() async throws {
        let harness = Harness()
        #expect(!harness.controller.isOn)
        #expect(!harness.controller.isListening)
        #expect(harness.capture.startCount == 0)

        await harness.controller.turnOn(for: try binding())
        #expect(harness.controller.isOn)
        #expect(harness.controller.isListening)
        #expect(harness.capture.startCount == 1)
        await harness.controller.turnOff()
        #expect(!harness.controller.isOn)
        #expect(harness.controller.stopReason == nil)
        #expect(harness.released == 1)
    }

    @Test func leavingTheForegroundStopsStreamingAndReturningDoesNotRestart() async throws {
        let harness = Harness()
        let current = try binding()
        await harness.controller.turnOn(for: current)
        #expect(harness.controller.isListening)

        await harness.controller.update(binding: current, scene: .inactive)
        #expect(!harness.controller.isOn)
        #expect(!harness.controller.isListening)
        #expect(harness.capture.stopCount >= 1)
        #expect(harness.released == 1)
        #expect(harness.controller.stopReason?.contains("foreground") == true)

        await harness.controller.update(binding: current, scene: .active)
        #expect(!harness.controller.isOn)
        #expect(harness.capture.startCount == 1)
    }

    @Test func backgroundAlsoStopsStreaming() async throws {
        let harness = Harness()
        let current = try binding()
        await harness.controller.turnOn(for: current)
        await harness.controller.update(binding: current, scene: .background)
        #expect(!harness.controller.isOn)
        #expect(!harness.controller.isListening)
    }

    @Test func targetChangeEndsTheStreamAndTheToggleReturnsToOff() async throws {
        let harness = Harness()
        let current = try binding()
        await harness.controller.turnOn(for: current)
        try harness.capture.yield(sineBuffer())
        try harness.capture.yield(sineBuffer(offset: 4_800))

        await harness.controller.update(binding: try binding(target: "tmux:other"), scene: .active)
        #expect(!harness.controller.isOn)
        #expect(!harness.controller.isListening)
        #expect(harness.controller.stopReason?.contains("destination") == true)
        #expect(harness.sent.last?.isFinal == true)
        #expect(Set(harness.sent.map(\.streamID)).count == 1)

        await harness.controller.update(binding: current, scene: .active)
        #expect(!harness.controller.isOn)
        #expect(harness.capture.startCount == 1)
    }

    @Test func reselectingTheSameTargetIsStillABindingChange() async throws {
        let harness = Harness()
        let current = try binding()
        await harness.controller.turnOn(for: current)
        let reselected = AmbientAudioBinding(
            hostID: current.hostID, targetID: current.targetID,
            connectionGeneration: current.connectionGeneration, selection: current.selection + 1
        )
        await harness.controller.update(binding: reselected, scene: .active)
        #expect(!harness.controller.isOn)
    }

    @Test func aSendFailureStopsListeningAndSurfacesTheReason() async throws {
        let harness = Harness()
        harness.sendError = HostConnectionFailure.remote("not_allowed: ambient busy")
        await harness.controller.turnOn(for: try binding())
        try harness.capture.yield(sineBuffer())
        try harness.capture.yield(sineBuffer(offset: 4_800))
        try harness.capture.yield(sineBuffer(offset: 9_600))

        try await waitUntil { await MainActor.run { !harness.controller.isOn } }
        #expect(!harness.controller.isListening)
        #expect(harness.controller.stopReason?.contains("ambient busy") == true)
        #expect(harness.released == 1)
    }

    @Test func theMicrophoneEndingTurnsTheToggleOff() async throws {
        let harness = Harness()
        await harness.controller.turnOn(for: try binding())
        harness.capture.stop()
        try await waitUntil { await MainActor.run { !harness.controller.isOn } }
        #expect(harness.controller.stopReason?.contains("microphone") == true)
    }

    @Test func deniedPermissionLeavesTheToggleOffWithAReason() async throws {
        let harness = Harness()
        harness.permission = false
        await harness.controller.turnOn(for: try binding())
        #expect(!harness.controller.isOn)
        #expect(harness.capture.startCount == 0)
        #expect(harness.controller.stopReason?.contains("Microphone access") == true)
    }
}

func binding(target: String = "tmux:ambient", selection: UInt64 = 0) throws -> AmbientAudioBinding {
    AmbientAudioBinding(hostID: try endpoint().id, targetID: target, connectionGeneration: UUID(), selection: selection)
}
