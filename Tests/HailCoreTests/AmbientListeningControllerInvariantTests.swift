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
        let first = try await enqueuePeer(rig)
        await rig.store.upsert(rig.endpoint)
        await rig.store.connect(rig.endpoint.id)
        await first.socket.flush()
        try await rig.store.selectTarget(host: rig.endpoint.id, targetID: rig.target.id)
        let original = try rig.currentBinding()
        await controller.turnOn(for: original)
        let intent = try #require(controller.listeningState.intent)
        #expect(intent.destination.endpointURL == rig.endpoint.url.absoluteString)
        mask.masksDuringReplies.toggle()
        #expect(controller.listeningState == .on(intent))

        await interruptAndResume(controller, center: rig.center, release: released.stream, intent: intent)
        _ = try await enqueuePeer(rig)
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

    private func enqueuePeer(_ rig: AmbientReconnectRig) async throws -> Peer {
        let peer = Peer()
        try await peer.socket.push(.hello(HelloInfo(versions: VersionNegotiation.supported,
            capabilities: ["ping", "stream_audio", "select_target"], deviceName: "Synthetic")))
        try await peer.socket.push(.targets([rig.target]))
        await rig.connector.enqueue(.socket(peer), for: rig.endpoint.url)
        return peer
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
        let socket = ArrivalSocket()

        func send(_ data: Data) async throws {
            try await socket.send(data)
            if case .control(.ping(let nonce)) = try FrameCoding.decode(data).payload {
                try await socket.push(.pong(nonce: nonce))
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
