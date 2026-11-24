import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AmbientTransportSendFailureTests {
    @Test(arguments: [false, true])
    func sendOnlyFailureReplacesReadySocket(atSocket: Bool) async throws {
        let loss = POSIXError(.ENOTCONN)
        let run = try AmbientTransportSendFailureRun(error: atSocket ? nil : loss)
        let rig = run.rig
        try await run.start(socketError: atSocket ? loss : nil)
        let original = try rig.currentBinding()
        let replacement = try await run.prepareReplacement()
        await run.retry.release() // Configure an immediate backoff before injecting the loss.
        try await run.failSend()
        await arrivalObserved { rig.controller.binding != original }
        let restored = try rig.currentBinding()
        #expect(rig.controller.binding == restored && restored.connectionGeneration != original.connectionGeneration)
        #expect(restored.targetID == original.targetID && restored.selection == original.selection)
        // The first admitted buffer renews the retired queue. Only subsequent fresh audio is encoded.
        for _ in 0..<3 { try rig.capture.yield(sineBuffer(frames: 14_400)) }
        await arrivalObserved { !rig.controller.reconnect.isPending }
        let frame = try #require(try await audioFrames(replacement).first)
        guard case .audio(let first) = frame.payload else { throw SocketTestError.unavailable }
        #expect(frame.target == original.targetID)
        #expect(first.isResume && first.sequence == 0 && first.streamID != run.firstAudio?.streamID)
        #expect(await rig.connector.openCount(for: rig.endpoint.url) == 2)
        #expect(await rig.socket.closeCount == 1)
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        #expect(rig.notices.map(\.outcome) == [.applied] && rig.unexpected.isEmpty)
        await run.close()
    }

    @Test func duplicateSendAndReceiveLossArmOnce() async throws {
        let run = try AmbientTransportSendFailureRun()
        let rig = run.rig
        try await run.start()
        let original = try rig.currentBinding()
        try await run.failSend()
        let pacing = try #require(rig.controller.reconnect.pacing)
        rig.controller.reconnect.sendFailed(POSIXError(.ENOTCONN), audio: try #require(run.firstAudio),
                                            binding: original, store: rig.store)
        await run.waitForBackoff() // Closing the failed socket also releases its pending receive.
        #expect(rig.controller.binding == original && rig.controller.isOn)
        #expect(rig.controller.reconnect.status == "Reconnecting…")
        try rig.capture.yield(sineBuffer())
        #expect(rig.capture.discardedCount == 1)
        #expect(rig.controller.reconnect.pacing === pacing && rig.controller.reconnect.isPending)
        #expect(rig.notices.isEmpty && rig.unexpected.isEmpty)
        await run.close()
        #expect(rig.notices.map(\.reason) == [.ownerStop])
        #expect(rig.controller.listeningState == .stopped(.ownerOff))
    }

    @Test(arguments: [HostConnectionFailure.remote("not_allowed: ambient busy"),
                      .remote("not_allowed: ambient target_policy_changed")])
    func nonTransportSendErrorStillStops(_ error: HostConnectionFailure) async throws {
        let run = try AmbientTransportSendFailureRun(error: error)
        try await expectHardStop(run, reason: AmbientRefusal.isPolicyStop(error)
            ? AmbientRefusal.policyStopReason : "Stopped: \(AmbientListeningController.describe(error))")
        #expect(run.rig.controller.listeningState == .stopped(AmbientRefusal.isPolicyStop(error)
            ? .policyDenied : .legacy(.hostRefused)))
    }

    @Test func cancellationAndCodecErrorsStillStop() async throws {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled), AmbientAudioError.conversionFailed,
                                   EncodingError.invalidValue(0, .init(codingPath: [], debugDescription: "Synthetic"))]
        for error in errors {
            let run = try AmbientTransportSendFailureRun(error: error)
            try await expectHardStop(run, reason: "Stopped: \(AmbientListeningController.describe(error))")
            #expect(run.rig.controller.listeningState == .stopped(.legacy(
                error is CancellationError || error is URLError ? .sendCancelled : .encodingFailed)))
        }
    }

    @Test func cancelledSocketSendKeepsTheOrdinaryStop() async throws {
        let error = URLError(.cancelled)
        let run = try AmbientTransportSendFailureRun(error: nil)
        let reason = "Stopped: \(AmbientListeningController.describe(error))"
        try await expectHardStop(run, reason: reason, socketError: error)
        #expect(run.rig.controller.listeningState == .stopped(.legacy(.sendCancelled)))
    }

    @Test func retiredStreamSocketFailureLeavesReplacementCaptureSending() async throws {
        let gate = HeldSocketSend()
        let nextCapture = FakeAudioCapture()
        let run = try AmbientTransportSendFailureRun(error: nil, nextCapture: nextCapture)
        let rig = run.rig
        try await run.start(socketError: POSIXError(.ENOTCONN), gate: gate)
        let original = try rig.currentBinding()
        try rig.capture.yield(sineBuffer(frames: 14_400))
        await gate.started.wait()
        let retiring = Task { await rig.controller.turnOff() }
        await arrivalObserved { !rig.controller.isOn }
        #expect(rig.controller.listeningState == .stopped(.ownerOff))
        await rig.controller.turnOn(for: original)
        try nextCapture.yield(sineBuffer(frames: 14_400))
        await arrivalObserved { run.lastSentAudio != nil }
        let current = try #require(run.lastSentAudio)
        #expect(current.streamID != run.firstAudio?.streamID)
        await gate.completion.release()
        await retiring.value // The old send has returned through both the socket and the controller.
        try #require(rig.controller.isListening && !rig.controller.reconnect.isPending)
        try nextCapture.yield(sineBuffer(frames: 14_400))
        // The first 300 ms buffer cannot produce sequence 3.
        await arrivalObserved { (run.lastSentAudio?.sequence ?? -1) >= 3 }
        #expect(run.lastSentAudio?.streamID == current.streamID)
        #expect(try rig.currentBinding() == original && nextCapture.discardedCount == 0)
        #expect(await rig.connector.openCount(for: rig.endpoint.url) == 1)
        #expect(rig.notices.isEmpty && rig.unexpected.isEmpty)
        await run.close()
    }

    @Test func notReadyOnAStaleSelectionKeepsTheOrdinaryStop() async throws {
        let run = try AmbientTransportSendFailureRun(error: nil) // The real store rejects this retired binding.
        let rig = run.rig
        try await run.start()
        let original = try rig.currentBinding()
        try await rig.store.selectTarget(host: rig.endpoint.id, targetID: original.targetID)
        let reselected = try rig.currentBinding()
        #expect(reselected.connectionGeneration == original.connectionGeneration && reselected != original)
        try await run.failSend()
        await arrivalObserved { !rig.controller.isOn || rig.controller.reconnect.isPending }
        #expect(!rig.controller.isOn && rig.notices.isEmpty)
        #expect(rig.controller.listeningState == .stopped(.ownerReselect))
        #expect(rig.unexpected == ["Stopped: the connection changed."])
        await run.close()
    }

    private func expectHardStop(_ run: AmbientTransportSendFailureRun, reason: String,
                                socketError: (any Error)? = nil) async throws {
        let rig = run.rig
        try await run.start(socketError: socketError)
        try await run.failSend()
        try #require(!rig.controller.reconnect.isPending)
        await arrivalObserved { !rig.controller.isOn }
        #expect(!rig.controller.isListening && rig.controller.stopReason == reason)
        #expect(rig.unexpected == [reason] && rig.notices.isEmpty)
        #expect(await rig.socket.closeCount == 0)
        await run.close()
    }
}

extension AmbientTransportSendFailureTests {
    @Test func ownerStopDuringRecoveryWins() async throws {
        try await checkVeto(.ownerStop)
    }

    @Test func privacyDuringRecoveryWins() async throws {
        try await checkVeto(.privacy)
    }

    private func checkVeto(_ reason: AmbientListeningReconnect.Reason) async throws {
        let run = try AmbientTransportSendFailureRun()
        let rig = run.rig
        try await run.start()
        try await run.failSend()
        try #require(rig.controller.reconnect.isPending)
        await run.waitForBackoff()
        let replacement = try await run.prepareReplacement()
        if reason == .privacy {
            await #expect(throws: HostConnectionFailure.notReady) {
                try await rig.store.setPrivacy(on: true, host: rig.endpoint.id)
            }
        } else {
            await rig.controller.turnOff()
        }
        await arrivalObserved { !rig.controller.isOn }
        #expect(rig.controller.listeningState == .stopped(reason == .privacy ? .privacyStop : .ownerOff))
        await run.retry.release()
        await run.waitForTargets()
        #expect(rig.notices.map(\.reason) == [reason] && rig.notices.map(\.outcome) == [.blocked])
        #expect(!rig.controller.isListening && !rig.controller.reconnect.isPending && rig.unexpected.isEmpty)
        #expect(rig.capture.startCount == 1 && rig.controller.binding == nil)
        #expect(try await audioFrames(replacement).isEmpty)
        await run.close()
    }

    @Test func captureEndingAfterSendLossShowsTapToResume() async throws {
        let run = try AmbientTransportSendFailureRun()
        let rig = run.rig
        try await run.start()
        try await run.failSend()
        try #require(rig.controller.reconnect.isPending)
        rig.capture.stop()
        await arrivalObserved { !rig.controller.isOn }
        #expect(rig.controller.listeningState == .stopped(.legacy(.systemCaptureEnded)))
        #expect(rig.notices.map(\.outcome) == [.failed] && rig.notices.first?.reason == .startFailed)
        #expect(rig.notices.first?.text.contains("tap to resume") == true && rig.unexpected.isEmpty)
        await run.close()
    }
}
