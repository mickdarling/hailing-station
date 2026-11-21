import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AmbientListeningControllerInvariantTests {
    @Test func preferenceInterruptionAndTransportRecoveryKeepTheSameIntent() async throws {
        let retry = OpenGate()
        let rig = try AmbientReconnectRig(retrySleep: { _ in await retry.wait() })
        let mask = AmbientReplyEchoGuard()
        let released = AsyncStream<Void>.makeStream()
        let controller = AmbientListeningController(
            notificationCenter: rig.center, requestPermission: { true },
            makeStreamer: { AmbientAudioStreamer(capture: mask.masking(rig.capture), send: $0) },
            releaseSession: { released.continuation.finish() }, sleep: { _ in throw CancellationError() },
            send: { [store = rig.store] in try await store.sendAudio($0, to: $1) }
        )
        rig.store.ambientController = controller
        let first = try await connectPeer(rig, at: rig.endpoint)
        try await rig.store.selectTarget(host: rig.endpoint.id, targetID: rig.target.id)
        let original = try rig.currentBinding()
        await controller.turnOn(for: original)
        let intent = try #require(controller.listeningState.intent)
        #expect(intent.destination.endpointURL == rig.endpoint.url.absoluteString)
        mask.masksDuringReplies.toggle()
        #expect(controller.listeningState == .on(intent))

        await interruptAndResume(controller, center: rig.center, release: released.stream, intent: intent)
        _ = try await enqueuePeer(rig, at: rig.endpoint)
        await first.socket.fail()
        await arrivalObserved { controller.reconnect.isPending }
        await controller.update(binding: nil, scene: .active)
        #expect(controller.listeningState == .on(intent))
        await retry.release()
        await arrivalObserved { controller.binding != original }
        for _ in 0..<3 { try rig.capture.yield(sineBuffer(frames: 14_400)) }
        await arrivalObserved { !controller.reconnect.isPending }
        #expect(controller.isListening && controller.listeningState == .on(intent))
        await controller.turnOff()
        await rig.store.disconnect(rig.endpoint.id)
    }

    private func interruptAndResume(_ controller: AmbientListeningController, center: NotificationCenter,
                                    release: AsyncStream<Void>, intent: AmbientListeningState.Intent) async {
        center.post(name: AVAudioEngineCapture.endedBySystem, object: nil,
                    userInfo: [AVAudioEngineCapture.endedCauseKey: AVAudioEngineCapture.interruptionCause])
        for await _ in release {}
        #expect(!controller.isListening && controller.listeningState == .on(intent))
        center.post(name: AudioCaptureEndingSignal.Names.interruption, object: nil,
                    userInfo: [AudioCaptureEndingSignal.Names.interruptionTypeKey: UInt(0)])
        await arrivalObserved { controller.isListening }
        #expect(controller.listeningState == .on(intent))
    }

    private func connectPeer(_ rig: AmbientReconnectRig, at endpoint: HostEndpoint) async throws -> Peer {
        let peer = try await enqueuePeer(rig, at: endpoint)
        await rig.store.upsert(endpoint)
        await rig.store.connect(endpoint.id)
        await arrivalObserved { rig.store.snapshots[endpoint.id]?.receivedTargetList == true }
        return peer
    }

    private func enqueuePeer(_ rig: AmbientReconnectRig, at endpoint: HostEndpoint) async throws -> Peer {
        let peer = Peer()
        try await peer.socket.push(.hello(HelloInfo(versions: VersionNegotiation.supported,
            capabilities: ["ping", "stream_audio", "select_target"], deviceName: "Synthetic")))
        try await peer.socket.push(.targets([rig.target]))
        await rig.connector.enqueue(.socket(peer), for: endpoint.url)
        return peer
    }

    enum StartStage: CaseIterable, Sendable { case permission, activation }

    @Test(arguments: StartStage.allCases)
    func ownerReselectRetiresPendingStart(_ stage: StartStage) async throws {
        let rig = try AmbientReconnectRig()
        rig.store.ambientController = rig.controller
        let first = try await connectPeer(rig, at: rig.endpoint)
        try await rig.store.selectTarget(host: rig.endpoint.id, targetID: rig.target.id)
        let binding = try rig.currentBinding()
        let second = try endpoint("second", "ws://127.0.0.1:8770")
        let peer = try await connectPeer(rig, at: second)
        var pings = await peer.holdNextPong().makeAsyncIterator()

        let gate = SleepGate()
        switch stage {
        case .permission: rig.permissionGate = gate
        case .activation: rig.activationGate = gate
        }
        let start = Task { await rig.controller.turnOn(for: binding) }
        for await _ in gate.firstSleep.stream {}
        let selection = Task { try await rig.store.selectTarget(host: second.id, targetID: rig.target.id) }
        let nonce = try #require(await pings.next())
        #expect(rig.controller.listeningState == .stopped(.ownerReselect))
        #expect(rig.controller.stopReason == OwnerDestinationRun.reason)
        #expect(!rig.controller.isListening)

        await gate.fire()
        await start.value
        #expect(rig.released == (stage == .activation ? 1 : 0))
        try rig.capture.yield(sineBuffer(frames: 14_400))
        rig.capture.stop()
        await arrivalObserved { !rig.controller.isListening }
        #expect(rig.capture.startCount == 0)
        #expect(try await audioFrames(first.socket).isEmpty)

        try await peer.socket.push(.pong(nonce: nonce))
        try await selection.value
        #expect(rig.controller.listeningState == .stopped(.ownerReselect))
        #expect(rig.capture.startCount == 0)
        #expect(try await audioFrames(peer.socket).isEmpty)
        await rig.close()
        await rig.store.disconnect(second.id)
    }

    @Test func initialCaptureFailureRetainsItsExistingStop() async throws {
        let controller = AmbientListeningController(requestPermission: { true },
            makeStreamer: { _ in throw AudioCaptureError.alreadyRunning },
            releaseSession: {}, send: { _, _ in })
        await controller.turnOn(for: try binding())
        #expect(controller.listeningState == .stopped(.legacy(.captureStartFailed)))
        #expect(controller.stopReason?.hasPrefix("Could not start listening: ") == true)
    }

    @Test func unclassifiedSendErrorRetainsItsExistingStop() async throws {
        struct LocalFailure: Error {}
        let harness = AmbientListeningControllerTests.Harness()
        harness.sendError = LocalFailure()
        await harness.controller.turnOn(for: try binding())
        try harness.capture.yield(sineBuffer(frames: 14_400))
        for await _ in harness.firstRelease.stream {}
        #expect(harness.controller.listeningState == .stopped(.legacy(.sendFailed)))
    }

    private actor Peer: WebSocketTransport {
        let socket = ScriptedSocket()
        private var heldPong: AsyncStream<String>.Continuation?

        func holdNextPong() -> AsyncStream<String> {
            let pair = AsyncStream<String>.makeStream()
            heldPong = pair.continuation
            return pair.stream
        }

        func send(_ data: Data) async throws {
            await socket.send(data)
            if case .control(.ping(let nonce)) = try FrameCoding.decode(data).payload {
                if let heldPong {
                    heldPong.yield(nonce)
                    heldPong.finish()
                    self.heldPong = nil
                } else {
                    try await socket.push(.pong(nonce: nonce))
                }
            }
        }

        func receive() async throws -> Data { try await socket.receive() }
        func close() async { await socket.close() }
    }
}

/// Some controller callbacks publish microphone inactivity before the scheduled intent write.
@MainActor
func ambientStateAfterStop(_ controller: AmbientListeningController) async -> AmbientListeningState {
    await arrivalObserved { !controller.isOn }
    return controller.listeningState
}
