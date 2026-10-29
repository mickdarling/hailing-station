import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientCallReviewTests {
    @Test(arguments: [false, true])
    func endingSignalDiscardsPCMThroughoutRouteWindow(interrupted: Bool) async throws {
        let rig = CallCaptureRig()
        await rig.controller.turnOn(for: try binding())
        let tap = try #require(rig.fakes[0].tap)
        rig.route(4)
        // The fake engine keeps delivering even after the ending signal, before any actor hop.
        for _ in 0..<20 { tap(try sineBuffer(), AVAudioTime(hostTime: 0)) }
        try await callEventually { await rig.routeWait.pending == 1 }
        // A fast same-host transport restore must not reopen this ending capture run.
        rig.streamers[0].resumeTransport()
        for _ in 0..<20 { tap(try sineBuffer(), AVAudioTime(hostTime: 0)) }
        if interrupted {
            rig.interruption(true)
            try await callEventually { await MainActor.run { rig.controller.pausedReason != nil } }
        } else {
            await rig.routeWait.release()
            try await callEventually { await MainActor.run { !rig.controller.isOn } }
        }
        await rig.streamers[0].stop() // Drain every supplied buffer and final tail before asserting.
        #expect(await rig.sent.payloads.isEmpty)
        #expect(rig.fakes.count == 1)
        await rig.close()
    }

    @Test func interruptionImmediatelyDiscardsPCMFromAYieldingTap() async throws {
        let rig = CallCaptureRig()
        await rig.controller.turnOn(for: try binding())
        let tap = try #require(rig.fakes[0].tap)
        rig.interruption(true)
        for _ in 0..<20 { tap(try sineBuffer(), AVAudioTime(hostTime: 0)) }
        await rig.streamers[0].stop()
        #expect(await rig.sent.payloads.isEmpty)
        #expect(rig.controller.isOn && rig.controller.pausedReason != nil)
        await rig.close()
    }

    @Test func privateSameSocketUsesFreshTransportAndConfirmedPreArm() async throws {
        let rig = try CallReconnectRig()
        let deadline = BackoffSteps()
        rig.controller.reconnect.sleep = { await deadline.sleep($0) }
        try await rig.start()
        try await rig.feed()
        try await rig.confirmPrivacy()
        let oldSocket = rig.socket
        let old = try rig.currentBinding()
        try await rig.interrupt()
        let sentAtPause = try await audioFrames(oldSocket).count
        rig.interruptionEnded()
        // A real already-private host sends no reply to a repeated same-socket set_privacy.
        try await callEventually { await MainActor.run {
            rig.controller.isListening || rig.controller.reconnect.isPending
        } }
        try #require(!rig.controller.isListening && rig.capture.startCount == 1)
        try await callEventually { await rig.retry.isWaiting() }
        #expect(rig.controller.isOn && !rig.controller.isListening && rig.capture.startCount == 1)
        rig.clock.advance(by: .seconds(6))
        let host = AmbientPrivacyHost(base: ScriptedSocket())
        try await replaceTransport(rig, with: host)
        let discarded = rig.capture.discardedCount
        for _ in 0..<20 { try rig.capture.yield(sineBuffer()) }
        #expect(rig.capture.discardedCount == discarded + 20)
        #expect(rig.controller.isOn && !rig.controller.isListening && rig.capture.startCount == 1)
        #expect(try await audioFrames(oldSocket).count == sentAtPause)
        #expect(try await audioFrames(rig.socket).isEmpty)
        try await host.answer()
        try await callEventually { await MainActor.run { rig.controller.isListening } }
        #expect(rig.controller.binding?.connectionGeneration != old.connectionGeneration)
        try await rig.feed()
        #expect(await host.audioBeforeConfirmation() == 0)
        #expect(!(try await audioFrames(rig.socket)).isEmpty)
        await rig.close()
        await deadline.release()
    }

    @Test(arguments: [false, true])
    func URLChangeDuringCallStopsWithVisibleReason(transportGone: Bool) async throws {
        let rig = try CallReconnectRig()
        try await rig.start()
        let oldSocket = rig.socket
        try await rig.interrupt()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .background)
        if transportGone { try await rig.drop() }
        var changed = rig.endpoint
        changed.url = try #require(URL(string: "ws://127.0.0.1:18766"))
        let newSocket = ScriptedSocket()
        await rig.connector.enqueue(.socket(newSocket), for: changed.url)
        await rig.store.upsert(changed)
        try await callEventually { await MainActor.run { !rig.controller.isOn } }
        let reason = "listening stopped: host address changed during call"
        #expect(rig.controller.stopReason == reason)
        #expect(rig.notices.last?.text == reason || rig.unexpected.contains(reason))
        rig.interruptionEnded()
        await rig.microphoneRetry.release()
        await rig.retry.fire()
        await rig.controller.update(binding: nil, scene: .active)
        #expect(!rig.controller.isOn && !rig.controller.isListening && rig.controller.pausedReason == nil)
        #expect(!rig.controller.reconnect.isPending && rig.capture.startCount == 1)
        #expect(try await audioFrames(oldSocket).isEmpty)
        #expect(try await audioFrames(newSocket).isEmpty)
        await rig.close()
    }

    private func replaceTransport(_ rig: CallReconnectRig, with host: AmbientPrivacyHost) async throws {
        rig.socket = host.base
        await rig.connector.enqueue(.socket(host), for: rig.endpoint.url)
        await rig.retry.fire()
        try await rig.handshake(rig.socket, mode: .duckMode(on: true))
        try await rig.confirmAutomaticSelection()
        try await callEventually { await host.receivedRequest() }
    }
}

extension AmbientCallReviewTests {
    @Test(arguments: [false, true])
    func startupSignalsUseTheRunningStateAfterEngineStart(category: Bool) async throws {
        let center = NotificationCenter()
        let engine = AVAudioEngine()
        let fake = FakeEngineOperations()
        let routeWait = BackoffSteps()
        let notes = PostedNotes(center, [AVAudioEngineCapture.endedBySystem])
        let sent = SentAudio()
        let evaluated = AudioEngineCaptureStartupSignalTests.EndedFlag()
        var evaluations = 0
        var operations = fake.operations
        operations.isRunning = { _ in
            evaluations += 1
            if evaluations >= 2 {
                evaluated.set()
            }
            return fake.running
        }
        operations.start = { _ in
            if category {
                center.post(name: AudioCaptureEndingSignal.Names.routeChange, object: nil,
                            userInfo: [AudioCaptureEndingSignal.Names.routeChangeReasonKey: UInt(3)])
            } else {
                center.post(name: .AVAudioEngineConfigurationChange, object: engine)
            }
            fake.running = true
        }
        let capture = AVAudioEngineCapture(
            engine: engine, notificationCenter: center, operations: operations,
            routeInputChanged: { _ in true }, sleep: { await routeWait.sleep($0) }
        )
        let streamer = AmbientAudioStreamer(capture: capture, send: { await sent.send($0) })
        try streamer.start()
        try await callEventually { evaluated.value }
        for _ in 0..<6 { fake.feed(try sineBuffer()) }
        await streamer.stop()
        #expect(notes.named(AVAudioEngineCapture.endedBySystem).isEmpty)
        #expect(!(await sent.payloads).isEmpty)
        await routeWait.release()
    }
}
