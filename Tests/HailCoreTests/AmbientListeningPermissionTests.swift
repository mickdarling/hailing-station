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
        await controller.update(binding: current, scene: .background)
        #expect(!controller.isOn)
        #expect(!controller.isListening)
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

@MainActor
@Suite struct HostConnectionStoreAmbientBindingTests {
    @Test func noBindingWithoutStreamAudioSoTheToggleStaysHidden() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target"])
        let (store, endpoint) = (ready.store, ready.endpoint)
        #expect(store.ambientBinding(host: endpoint.id, targetID: "tmux:a") == nil)
        await #expect(throws: HostConnectionFailure.notReady) {
            try await store.sendAudio(ambientSegment(), to: AmbientAudioBinding(
                hostID: endpoint.id, targetID: "tmux:a", connectionGeneration: UUID(), selection: 0
            ))
        }
        await store.disconnect(endpoint.id)
    }

    @Test func anyTargetSelectionInvalidatesTheBinding() async throws {
        let ready = try await readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        let before = try #require(store.ambientBinding(host: endpoint.id, targetID: "tmux:a"))
        let selection = Task { try await store.selectTarget(host: endpoint.id, targetID: "tmux:a") }
        try await waitUntil {
            await MainActor.run { store.ambientBinding(host: endpoint.id, targetID: "tmux:a") != before }
        }
        await #expect(throws: HostConnectionFailure.notReady) {
            try await store.sendAudio(ambientSegment(), to: before)
        }
        await store.disconnect(endpoint.id)
        _ = await selection.result
        #expect(try await audioFrames(socket).isEmpty)
        #expect(store.ambientBinding(host: endpoint.id, targetID: "tmux:a") == nil)
    }

    struct ReadyStore {
        let store: HostConnectionStore
        let endpoint: HostEndpoint
        let socket: ScriptedSocket
    }

    private func readyStore(
        capabilities: [String]
    ) async throws -> ReadyStore {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() })
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: capabilities, deviceName: "Mac"
        )))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state == .ready } }
        return ReadyStore(store: store, endpoint: endpoint, socket: socket)
    }
}
