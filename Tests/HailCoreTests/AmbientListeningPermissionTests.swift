import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Scene rules around the microphone permission request for the ambient toggle (#203 PR 5).
@MainActor
@Suite struct AmbientListeningPermissionTests {
    @Test func turningOnOutsideTheForegroundDoesNothing() async throws {
        let harness = AmbientListeningControllerTests.Harness()
        await harness.controller.update(binding: nil, scene: .inactive)
        await harness.controller.turnOn(for: try binding())
        #expect(!harness.controller.isOn)
        #expect(harness.capture.startCount == 0)
    }

    /// The permission alert itself makes the scene inactive; that must not cancel the user's request.
    @Test func thePermissionAlertDoesNotCancelTheRequest() async throws {
        let held = heldPermissionController()
        let (controller, permission, capture) = (held.controller, held.permission, held.capture)
        let current = try binding()
        let request = Task { await controller.turnOn(for: current) }
        try await waitUntil { await MainActor.run { permission.isHeld } }
        await controller.update(binding: current, scene: .inactive)
        permission.resolve(true)
        await request.value
        #expect(controller.isOn)
        #expect(!controller.isListening)
        #expect(capture.startCount == 0)

        await controller.update(binding: current, scene: .active)
        #expect(controller.isListening)
        // Once streaming, the background no longer stops it (#282).
        await controller.update(binding: current, scene: .background)
        #expect(controller.isListening)
    }

    @Test func backgroundingDuringThePermissionRequestCancelsIt() async throws {
        let held = heldPermissionController()
        let (controller, permission, capture) = (held.controller, held.permission, held.capture)
        let current = try binding()
        let request = Task { await controller.turnOn(for: current) }
        try await waitUntil { await MainActor.run { permission.isHeld } }
        await controller.update(binding: current, scene: .background)
        permission.resolve(true)
        await request.value
        await controller.update(binding: current, scene: .active)
        #expect(!controller.isOn)
        #expect(capture.startCount == 0)
        #expect(controller.listeningState == .stopped(.legacy(.leftForeground)))
    }

    @Test func sceneDisposalRetiresTheStartAwaitingPermission() async throws {
        let gate = OpenGate()
        let capture = FakeAudioCapture()
        let controller = AmbientListeningController(requestPermission: { await gate.wait(); return true },
            makeStreamer: { AmbientAudioStreamer(capture: capture, send: $0) },
            releaseSession: {}, send: { _, _ in })
        let store = HostConnectionStore()
        store.ambientController = controller
        let current = try binding()
        let start = Task { await controller.turnOn(for: current) }
        do {
            try await waitForAudioTestState { await controller.isOn }
        } catch {
            await gate.release()
            await start.value
            await controller.turnOff()
            throw error
        }
        store.disposeStationScene()
        #expect(controller.listeningState == .stopped(.sceneDisposed))
        await gate.release()
        await start.value
        #expect(capture.startCount == 0 && store.ambientController == nil)

        let late = AmbientListeningControllerTests.Harness()
        store.ambientController = late.controller
        await late.controller.turnOn(for: current)
        #expect(store.ambientController == nil && late.capture.startCount == 0)
        await late.controller.turnOff()
    }

    struct Held {
        let controller: AmbientListeningController
        let permission: HeldPermission
        let capture: FakeAudioCapture
    }

    @MainActor
    final class HeldPermission {
        private var continuation: CheckedContinuation<Bool, Never>?
        var isHeld: Bool { continuation != nil }
        func request() async -> Bool { await withCheckedContinuation { continuation = $0 } }
        func resolve(_ granted: Bool) {
            continuation?.resume(returning: granted)
            continuation = nil
        }
    }

    private func heldPermissionController() -> Held {
        let permission = HeldPermission()
        let capture = FakeAudioCapture()
        let controller = AmbientListeningController(
            requestPermission: { await permission.request() },
            makeStreamer: { send in AmbientAudioStreamer(capture: capture, send: send) },
            releaseSession: {},
            send: { _, _ in }
        )
        return Held(controller: controller, permission: permission, capture: capture)
    }
}
