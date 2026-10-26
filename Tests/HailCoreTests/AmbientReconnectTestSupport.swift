import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
final class AmbientReconnectRig {
    let connector = ScriptedConnector()
    let retry = SleepGate()
    let endpoint: HostEndpoint
    let capture = FakeAudioCapture()
    let target = TargetInfo(id: "tmux:synthetic", kind: "tmux", name: "Synthetic", alive: true)
    var socket = ScriptedSocket()
    var transport: (any WebSocketTransport)?
    var permission = true
    var failStart = false
    var permissionCalls = 0
    var makeCalls = 0
    var notices: [AmbientListeningReconnect.Notice] = []
    var permissionGate: SleepGate?
    var activationGate: SleepGate?
    let store: HostConnectionStore
    lazy var controller = makeController()

    private func makeController() -> AmbientListeningController {
        AmbientListeningController(
        notificationCenter: NotificationCenter(), requestPermission: { [weak self] in
            guard let self else { return false }
            self.permissionCalls += 1
            if let gate = self.permissionGate { try? await gate.sleep(.zero) }
            return self.permission
        },
        makeStreamer: { [weak self] send in
            guard let self else { throw CancellationError() }
            self.makeCalls += 1
            if let gate = self.activationGate { try? await gate.sleep(.zero) }
            if self.failStart { throw AudioCaptureError.alreadyRunning }
            return AmbientAudioStreamer(capture: self.capture, send: send)
        },
        releaseSession: {}, send: { [weak self] payload, binding in
            guard let store = self?.store else { throw HostConnectionFailure.notReady }
            try await store.sendAudio(payload, to: binding)
        }
    )
    }

    init() throws {
        endpoint = try makeReconnectEndpoint()
        let retry = retry
        store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() },
                                    sleep: { delay in try await retry.sleep(delay) })
    }

    func start(listening: Bool = true) async throws {
        store.ambientController = controller
        controller.reconnect.onNotice = { [weak self] in self?.notices.append($0) }
        await connector.enqueue(.socket(transport ?? socket), for: endpoint.url)
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await handshake(socket)
        try await select(restoring: false)
        if listening { await controller.turnOn(for: try currentBinding()) }
    }

    func currentBinding() throws -> AmbientAudioBinding {
        try #require(store.ambientBinding(host: endpoint.id, targetID: target.id))
    }

    func drop() async throws {
        await socket.fail()
        try await waitUntil { await self.retry.isWaiting() }
        if controller.reconnect.isPending {
            try await waitUntil { await MainActor.run { !self.controller.isOn } }
        }
    }

    func reconnect(selectTarget: Bool = true, mode: ControlPayload? = nil) async throws {
        socket = ScriptedSocket()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        await retry.fire()
        try await handshake(socket, mode: mode)
        if selectTarget { try await select(restoring: true) }
    }

    func handshake(_ socket: ScriptedSocket, mode: ControlPayload? = nil) async throws {
        try await waitUntil { try await socket.sentFrames().contains { if case .control(.hello) = $0.payload {
            return true
        }; return false } }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["ping", "select_target", "stream_audio", "set_privacy"],
            deviceName: "Synthetic"
        )))
        if let mode { try await socket.push(mode) }
        try await socket.push(.targets([target]))
        try await waitUntil { await MainActor.run {
            self.store.snapshots[self.endpoint.id]?.receivedTargetList == true
        } }
    }

    func select(restoring: Bool, targetID: String? = nil) async throws {
        let count = try await socket.sentFrames().count
        let task = Task {
            try await store.selectTarget(host: endpoint.id, targetID: targetID ?? target.id, restoring: restoring)
        }
        do {
            try await waitUntil { try await self.selectionPing(after: count) != nil }
            let ping = try #require(try await selectionPing(after: count))
            try await socket.push(.pong(nonce: ping))
            try await task.value
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    func selectionPing(after count: Int) async throws -> String? {
        let frames = Array(try await socket.sentFrames().dropFirst(count))
        guard let index = frames.firstIndex(where: { if case .control(.select) = $0.payload {
            return true
        }; return false }) else { return nil }
        return frames.dropFirst(index).compactMap { frame -> String? in
            if case .control(.ping(let nonce)) = frame.payload { return nonce }; return nil
        }.first
    }

    func expectStopped(_ reason: AmbientListeningReconnect.Reason) async throws {
        try await waitUntil { await MainActor.run { !self.notices.isEmpty } }
        #expect(!controller.isListening)
        #expect(!controller.isOn)
        #expect(capture.startCount == 1)
        #expect(notices.count == 1)
        #expect(notices.last?.outcome == .blocked)
        #expect(notices.last?.reason == reason)
        #expect(notices.last?.text.contains("tap to resume") == true)
    }

    func close() async {
        await controller.turnOff()
        await store.disconnect(endpoint.id)
        await retry.fire()
    }
}

// The repository's endpoint helper always uses loopback; no real device or host identity is involved.
private func makeReconnectEndpoint() throws -> HostEndpoint { try endpoint() }
