import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Scheduling watchdog only: protocol time advances exclusively through injected waits and signals.
func callEventually(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    for _ in 0..<100_000 {
        if try await condition() { return }
        await Task.yield()
    }
    Issue.record("Call fixture did not reach its signalled state")
    throw CancellationError()
}

@MainActor
@Suite(.serialized) struct AmbientCallResumeTests {
    @Test(arguments: [UInt(4), UInt(3)])
    func routeBeforeInterruptionPausesAndResumes(reason: UInt) async throws {
        let rig = CallCaptureRig()
        await rig.controller.turnOn(for: try binding())
        rig.fakes[0].running = reason != 3 // A category change ends capture only when the engine stopped.
        rig.route(reason)
        // Wait for the actual route evaluation before posting the interruption: the reported device ordering.
        try await callEventually { await MainActor.run { rig.routeEvaluated } }
        rig.interruption(true)
        try await callEventually { await MainActor.run { rig.controller.pausedReason != nil || !rig.controller.isOn } }
        try #require(rig.controller.isOn && rig.controller.pausedReason != nil)
        #expect(!rig.controller.isListening)
        rig.interruption(false)
        try await callEventually { await MainActor.run { rig.controller.isListening } }
        #expect(rig.fakes.count == 2)
        await rig.close()
    }

    @Test func routeWithoutInterruptionEndsAtTheInjectedWindow() async throws {
        let rig = CallCaptureRig()
        await rig.controller.turnOn(for: try binding())
        rig.route(4)
        try await callEventually { await MainActor.run { rig.routeEvaluated } }
        try #require(rig.controller.isOn)
        try await callEventually { await rig.routeWait.pending == 1 }
        #expect(await rig.routeWait.durations == [.milliseconds(200)])
        await rig.routeWait.release()
        try await callEventually { await MainActor.run { !rig.controller.isOn } }
        #expect(rig.controller.pausedReason == nil)
        await rig.close()
    }

    @Test func pauseSurvivesNewGenerationOnSameDestination() async throws {
        let rig = CallCaptureRig()
        let old = try binding()
        await rig.controller.turnOn(for: old)
        rig.interruption(true)
        try await callEventually { await MainActor.run { rig.controller.pausedReason != nil && !rig.controller.isListening } }
        let new = AmbientAudioBinding(hostID: old.hostID, targetID: old.targetID,
                                     connectionGeneration: UUID(), selection: old.selection)
        await rig.controller.update(binding: new, scene: .background)
        try #require(rig.controller.isOn)
        #expect(rig.controller.binding == new && rig.controller.pausedReason != nil)
        await rig.controller.update(binding: new, scene: .active)
        #expect(rig.controller.isListening)
        await rig.close()
    }

    @Test func longCallStillResumesAndOwnerStopDoesNot() async throws {
        let rig = CallCaptureRig()
        await rig.controller.turnOn(for: try binding())
        rig.busy = true
        rig.interruption(true)
        for _ in 0..<15 {
            try await callEventually { await rig.retry.pending == 1 }
            await rig.retry.release()
        }
        try await callEventually { await rig.retry.pending == 1 }
        #expect(await rig.retry.durations.reduce(.zero, +) > .seconds(600))
        #expect(rig.controller.isOn && rig.controller.pausedReason != nil)
        rig.busy = false
        rig.interruption(false)
        try await callEventually { await MainActor.run { rig.controller.isListening } }
        rig.interruption(true)
        try await callEventually { await MainActor.run { rig.controller.pausedReason != nil && rig.releases >= 2 } }
        await rig.controller.turnOff()
        rig.interruption(false)
        await rig.retry.release()
        // A synchronous foreground trigger is a barrier through the same resume entry point.
        await rig.controller.update(binding: try binding(), scene: .active)
        #expect(!rig.controller.isOn && rig.fakes.count == 2)
        await rig.close()
    }

    @Test func offBeforeCallStaysOff() async throws {
        let rig = CallCaptureRig()
        rig.interruption(true)
        rig.interruption(false)
        await rig.controller.update(binding: try binding(), scene: .active)
        #expect(!rig.controller.isOn && rig.fakes.isEmpty)
        await rig.close()
    }

    @Test(arguments: [true, false])
    func privacyTapDuringCallCancelsResume(on: Bool) async throws {
        let rig = try CallReconnectRig()
        try await rig.start()
        try await rig.confirmPrivacy()
        try await rig.interrupt()
        try await rig.store.setPrivacy(on: on, host: rig.endpoint.id)
        try await rig.socket.push(.duckMode(on: on, reason: "device"))
        try await callEventually { await MainActor.run { !rig.controller.isOn } }
        rig.interruptionEnded()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        #expect(!rig.controller.isOn && rig.capture.startCount == 1)
        await rig.close()
    }

    @Test(arguments: [false, true])
    func privateResumeWaitsForConfirmationAcrossCall(reconnecting: Bool) async throws {
        let rig = try CallReconnectRig()
        let privacyWait = BackoffSteps()
        rig.controller.reconnect.sleep = { await privacyWait.sleep($0) }
        try await rig.start()
        try await rig.confirmPrivacy()
        let old = rig.controller.binding
        try await rig.interrupt()
        if reconnecting { try await rig.drop() }
        let host = AmbientPrivacyHost(base: reconnecting ? ScriptedSocket() : rig.socket)
        if reconnecting {
            rig.socket = host.base
            await rig.connector.enqueue(.socket(host), for: rig.endpoint.url)
            await rig.retry.fire()
            try await rig.handshake(rig.socket, mode: .duckMode(on: true)) // Park restored by the host.
            try await rig.confirmAutomaticSelection()
        }
        rig.interruptionEnded()
        // Same-socket requests are observed on the scripted socket; the reconnect uses a held host response.
        try await callEventually {
            if reconnecting { return await host.receivedRequest() }
            return try await rig.socket.sentFrames().filter { $0.payload == .control(.setPrivacy(on: true)) }.count == 2
        }
        #expect(!rig.controller.isListening && rig.capture.startCount == 1)
        if reconnecting { try await host.answer() } else { try await rig.socket.push(.duckMode(on: true)) }
        try await callEventually { await MainActor.run { rig.controller.isListening } }
        #expect(rig.store.privacySwitch(rig.endpoint.id).isPrivate)
        if reconnecting { #expect(rig.controller.binding?.connectionGeneration != old?.connectionGeneration) }
        try await rig.feed()
        try await callEventually { try await rig.socket.sentFrames().contains { if case .audio = $0.payload {
            return true
        }; return false } }
        let frames = try await rig.socket.sentFrames()
        let first = try #require(frames.compactMap { frame -> AudioPayload? in
            if case .audio(let audio) = frame.payload { return audio }; return nil
        }.first)
        #expect(first.isResume && first.sequence == 0)
        if reconnecting { await #expect(host.audioBeforeConfirmation() == 0) }
        await rig.close()
        await privacyWait.release()
    }
}

