import Foundation
import HailProtocol
import Observation
import Testing
@testable import HailCore

/// The first audio write can fail at the controller or at the scripted peer. Receive stays open until close.
@MainActor
@Observable
final class AmbientTransportSendFailureRun {
    let rig: AmbientReconnectRig
    let retry = OpenGate()
    let failed = AsyncStream<Void>.makeStream()
    private(set) var firstAudio: AudioPayload?
    private(set) var lastSentAudio: AudioPayload?
    private let error: (any Error)?

    init(error: (any Error)? = POSIXError(.ENOTCONN), nextCapture: FakeAudioCapture? = nil) throws {
        self.error = error
        let retry = retry
        rig = try AmbientReconnectRig(retrySleep: { _ in await retry.wait() })
        let clock = TestInstantClock()
        let completed = failed.continuation
        rig.controller = AmbientListeningController(
            notificationCenter: rig.center, requestPermission: { true },
            makeStreamer: { [capture = rig.capture] send in
                let input = capture.startCount == 0 ? capture : nextCapture ?? capture
                return AmbientAudioStreamer(capture: input) { audio in
                    do { try await send(audio) } catch {
                        completed.finish() // The controller has handled this error, including admission retirement.
                        throw error
                    }
                }
            }, releaseSession: {}, now: { clock.now() },
            send: { [weak self] audio, binding in
                guard let self else { throw CancellationError() }
                try await self.send(audio, binding: binding)
            }
        )
        rig.controller.reconnect.now = { clock.now() }
        rig.store.ambientController = rig.controller
        rig.controller.onUnexpectedStop = { [weak rig] in rig?.unexpected.append($0) }
        rig.controller.reconnect.onNotice = { [weak rig] in rig?.notices.append($0) }
    }

    private func send(_ audio: AudioPayload, binding: AmbientAudioBinding) async throws {
        if firstAudio == nil {
            firstAudio = audio
            if let error { throw error }
        }
        try await rig.store.sendAudio(audio, to: binding)
        lastSentAudio = audio
    }

    func start(socketError: (any Error)? = nil, gate: HeldSocketSend? = nil) async throws {
        try await enqueueSocket(rig.socket, error: socketError, gate: gate)
        await rig.store.upsert(rig.endpoint)
        await rig.store.connect(rig.endpoint.id)
        await waitForTargets()
        try await rig.store.selectTarget(host: rig.endpoint.id, targetID: rig.target.id)
        await rig.controller.turnOn(for: try rig.currentBinding())
    }

    func failSend() async throws {
        try rig.capture.yield(sineBuffer(frames: 14_400))
        for await _ in failed.stream {}
    }

    func waitForBackoff() async {
        await arrivalObserved { [rig] in
            if case .reconnecting = rig.store.snapshots[rig.endpoint.id]?.state { return true }
            return false
        }
    }

    func prepareReplacement() async throws -> ScriptedSocket {
        let replacement = ScriptedSocket()
        try await enqueueSocket(replacement)
        return replacement
    }

    private func enqueueSocket(_ socket: ScriptedSocket, error: (any Error)? = nil,
                               gate: HeldSocketSend? = nil) async throws {
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["ping", "select_target", "stream_audio", "set_privacy"],
            deviceName: "Synthetic"
        )))
        try await socket.push(.targets([rig.target]))
        let peer = AnsweringSocket(base: socket, audioError: error, gate: gate)
        await rig.connector.enqueue(.socket(peer), for: rig.endpoint.url)
    }

    func waitForTargets() async {
        await arrivalObserved { [rig] in
            rig.store.snapshots[rig.endpoint.id]?.receivedTargetList == true
        }
    }

    func close() async {
        await rig.controller.turnOff()
        await rig.store.disconnect(rig.endpoint.id)
        await retry.release()
    }
}

struct HeldSocketSend: Sendable {
    let started = OpenGate()
    let completion = OpenGate()
}

/// A selection round trip completes through the ordinary receive loop.
actor AnsweringSocket: WebSocketTransport {
    let base: ScriptedSocket
    private var audioError: (any Error)?
    private var gate: HeldSocketSend?

    init(base: ScriptedSocket, audioError: (any Error)?, gate: HeldSocketSend?) {
        self.base = base
        self.audioError = audioError
        self.gate = gate
    }

    func send(_ data: Data) async throws {
        let payload = try FrameCoding.decode(data).payload
        if case .audio = payload {
            let failure = audioError
            audioError = nil
            if let gate {
                self.gate = nil
                await gate.started.release()
                await gate.completion.wait()
            }
            if let failure { throw failure }
        }
        await base.send(data)
        if case .control(.ping(let nonce)) = payload {
            try await base.push(.pong(nonce: nonce))
        }
    }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
}
