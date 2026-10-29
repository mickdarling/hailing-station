import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// A single authorized destination; no reconnect, privacy, permission or route-change fixture machinery.
@MainActor
final class CallPolicyHostRig {
    let center = NotificationCenter()
    let connector = CallPolicyConnector()
    let retry = CallPolicySignal()
    let microphoneRetry = CallPolicySignal()
    let endpoint: HostEndpoint
    let capture = CallPolicyCapture()
    let target = TargetInfo(id: "tmux:synthetic", kind: "tmux", name: "Synthetic", alive: true)
    let socket = CallPolicySocket()
    var transport: (any WebSocketTransport)?
    var released = 0
    var unexpected: [String] = []
    var notices: [AmbientListeningReconnect.Notice] = []
    let store: HostConnectionStore
    private let instant = ContinuousClock.now
    lazy var controller = makeController()

    init() throws {
        endpoint = try HostEndpoint(id: "policy-host", name: "Synthetic", url: #require(
            URL(string: "ws://127.0.0.1:18765")
        ))
        let retry = retry
        store = HostConnectionStore(
            connector: connector, deadlineSleep: { _ in throw CancellationError() },
            sleep: { _ in await retry.wait() }, jitter: { 0.5 }
        )
    }

    private func makeController() -> AmbientListeningController {
        AmbientListeningController(
            notificationCenter: center, requestPermission: { true },
            makeStreamer: { [capture] send in AmbientAudioStreamer(capture: capture, send: send) },
            releaseSession: { [weak self] in self?.released += 1 },
            sleep: { [microphoneRetry] _ in await microphoneRetry.wait() }, now: { [instant] in instant },
            send: { [weak self] payload, binding in
                guard let store = self?.store else {
                    throw HostConnectionFailure.notReady
                }
                try await store.sendAudio(payload, to: binding)
            }
        )
    }

    func start() async throws {
        controller.reconnect.now = { [instant] in instant }
        store.ambientController = controller
        controller.onUnexpectedStop = { [weak self] in self?.unexpected.append($0) }
        controller.reconnect.onNotice = { [weak self] in self?.notices.append($0) }
        await connector.enqueue(transport ?? socket)
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await handshake()
        try await select()
        await controller.turnOn(for: try currentBinding())
    }

    private func handshake() async throws {
        try await callPolicyEventually { try await self.socket.sentFrames().contains {
            if case .control(.hello) = $0.payload {
                return true
            }
            return false
        } }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["ping", "select_target", "stream_audio"],
            deviceName: "Synthetic"
        )))
        try await socket.push(.targets([target]))
        try await callPolicyEventually { await MainActor.run {
            self.store.snapshots[self.endpoint.id]?.receivedTargetList == true
        } }
    }

    private func select() async throws {
        let selection = Task {
            try await store.selectTarget(host: endpoint.id, targetID: target.id)
        }
        do {
            try await callPolicyEventually { try await self.socket.selectionPing() != nil }
            let ping = try #require(try await socket.selectionPing())
            try await socket.push(.pong(nonce: ping))
            try await selection.value
        } catch {
            selection.cancel()
            _ = await selection.result
            throw error
        }
    }

    func currentBinding() throws -> AmbientAudioBinding {
        try #require(store.ambientBinding(host: endpoint.id, targetID: target.id))
    }

    func feed() throws {
        for _ in 0..<6 {
            try capture.yield(callPolicyBuffer())
        }
    }

    func interrupt() async throws {
        center.post(name: AVAudioEngineCapture.endedBySystem, object: nil, userInfo: [
            AVAudioEngineCapture.endedCauseKey: AVAudioEngineCapture.interruptionCause
        ])
        try await callPolicyEventually { await MainActor.run {
            self.controller.pausedReason != nil && self.released == 1
        } }
    }

    func interruptionEnded() {
        center.post(name: AudioCaptureEndingSignal.Names.interruption, object: nil,
                    userInfo: [AudioCaptureEndingSignal.Names.interruptionTypeKey: UInt(0)])
    }

    func close() async {
        await controller.turnOff()
        await store.disconnect(endpoint.id)
        await retry.releaseAll()
        await microphoneRetry.releaseAll()
    }
}
