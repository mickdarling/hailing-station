import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
final class CallReconnectRig {
    let clock = TestInstantClock()
    let center = NotificationCenter()
    let connector = ScriptedConnector()
    let retry = SleepGate()
    let endpoint: HostEndpoint
    let capture = FakeAudioCapture()
    let target = TargetInfo(id: "tmux:synthetic", kind: "tmux", name: "Synthetic", alive: true)
    var socket = ScriptedSocket()
    var transport: (any WebSocketTransport)?
    var wrapReconnect: (ScriptedSocket) -> any WebSocketTransport = { $0 }
    var echoGuard: AmbientReplyEchoGuard?
    var released = 0
    var unexpected: [String] = []
    var permission = true
    var failStart = false
    var permissionCalls = 0
    var makeCalls = 0
    var notices: [AmbientListeningReconnect.Notice] = []
    let microphoneRetry = BackoffSteps()
    var permissionGate: SleepGate?
    var activationGate: SleepGate?
    let store: HostConnectionStore
    lazy var controller = makeController()

    private func makeController() -> AmbientListeningController {
        AmbientListeningController(
        notificationCenter: center, requestPermission: { [weak self] in
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
            return AmbientAudioStreamer(capture: self.echoGuard?.masking(self.capture) ?? self.capture, send: send)
        },
        releaseSession: { [weak self] in self?.released += 1 },
        sleep: { [microphoneRetry] in await microphoneRetry.sleep($0) }, now: { [clock] in clock.now() },
        send: { [weak self] payload, binding in
            guard let store = self?.store else { throw HostConnectionFailure.notReady }
            try await store.sendAudio(payload, to: binding)
        }
    )
    }

    init(retrySleep: HostConnection.Sleep? = nil, jitter: @escaping HostConnection.Jitter = { 0.5 }) throws {
        endpoint = try makeReconnectEndpoint()
        let retry = retry
        store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() },
                                    sleep: retrySleep ?? { delay in try await retry.sleep(delay) }, jitter: jitter)
    }

    func interrupt() async throws {
        center.post(name: AVAudioEngineCapture.endedBySystem, object: nil, userInfo: [
            AVAudioEngineCapture.endedCauseKey: AVAudioEngineCapture.interruptionCause
        ])
        try await callEventually { await MainActor.run { self.controller.pausedReason != nil && self.released == 1 } }
    }

    func interruptionEnded() {
        center.post(name: AudioCaptureEndingSignal.Names.interruption, object: nil,
                    userInfo: [AudioCaptureEndingSignal.Names.interruptionTypeKey: UInt(0)])
    }

    func confirmPrivacy() async throws {
        try await store.setPrivacy(on: true, host: endpoint.id)
        try await socket.push(.duckMode(on: true, reason: "device"))
        try await callEventually { await MainActor.run {
            self.store.privacySwitch(self.endpoint.id).isPrivate && self.store.privacyLocal[self.endpoint.id] == nil
        } }
    }

    func start(listening: Bool = true) async throws {
        controller.reconnect.now = { [clock] in clock.now() }
        store.ambientController = controller
        controller.onUnexpectedStop = { [weak self] in self?.unexpected.append($0) }
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
        try await callEventually { await self.retry.isWaiting() }
    }

    func reconnect(selectTarget: Bool = true, mode: ControlPayload? = nil) async throws {
        socket = ScriptedSocket()
        await connector.enqueue(.socket(wrapReconnect(socket)), for: endpoint.url)
        await retry.fire()
        try await handshake(socket, mode: mode)
        if selectTarget {
            try await select(restoring: true)
            
        }
    }

    func feed() async throws {
        for index in 0..<6 { try capture.yield(sineBuffer(offset: index * 4_800)) }
        if controller.reconnect.isPending {
            try await callEventually { await MainActor.run { !self.controller.reconnect.isPending } }
        }
    }

    func handshake(_ socket: ScriptedSocket, mode: ControlPayload? = nil) async throws {
        try await callEventually { try await socket.sentFrames().contains { if case .control(.hello) = $0.payload {
            return true
        }; return false } }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["ping", "select_target", "stream_audio", "set_privacy"],
            deviceName: "Synthetic"
        )))
        if let mode { try await socket.push(mode) }
        try await socket.push(.targets([target]))
        try await callEventually { await MainActor.run {
            self.store.snapshots[self.endpoint.id]?.receivedTargetList == true
        } }
    }
}

extension CallReconnectRig {
    func select(restoring: Bool, targetID: String? = nil) async throws {
        if restoring, controller.reconnect.isReauthorizing {
            try await confirmAutomaticSelection()
            return
        }
        let count = try await socket.sentFrames().count
        let task = Task {
            try await store.selectTarget(host: endpoint.id, targetID: targetID ?? target.id, restoring: restoring)
        }
        do {
            try await callEventually { try await self.selectionPing(after: count) != nil }
            let ping = try #require(try await selectionPing(after: count))
            try await socket.push(.pong(nonce: ping))
            try await task.value
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    func confirmAutomaticSelection() async throws {
        try await callEventually { try await self.selectionPing(after: 0) != nil }
        let ping = try #require(try await selectionPing(after: 0))
        try await socket.push(.pong(nonce: ping))
        try await callEventually { await MainActor.run {
            self.store.ambientBinding(host: self.endpoint.id, targetID: self.target.id) != nil
                || !self.controller.reconnect.isPending
        } }
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

    func close() async {
        await controller.turnOff()
        await store.disconnect(endpoint.id)
        await retry.fire()
    }
}

private func makeReconnectEndpoint() throws -> HostEndpoint { try endpoint() }
