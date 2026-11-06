import Foundation
import Testing
@testable import HailCore
@testable import HailDaemonKit

@MainActor
@Suite(.serialized) struct AmbientCallPolicyAdmissionTests {
    @Test func unannouncedPolicyWriteAdmitsOneSegmentThenStopsOnRefusal() async throws {
        try await refusedAdmission(denyBeforePause: false)
    }

    @Test func retainedDenyAdmitsOneSegmentThenStopsOnRefusal() async throws {
        try await refusedAdmission(denyBeforePause: true)
    }

    private func refusedAdmission(denyBeforePause: Bool) async throws {
        let rig = try CallPolicyHostRig()
        let host = try await CallPolicyHost.make(base: rig.socket, target: rig.target.id)
        rig.transport = host
        try await rig.start()
        if !denyBeforePause {
            try rig.feed()
            await host.awaitInput()
            let refusal = await host.firstRefusal
            try #require(host.sink.segmentCount > 0, "Initial synthetic stream refused: \(refusal ?? "none")")
        }
        if denyBeforePause {
            _ = try await host.host.deny(rig.target.id)
        }
        try await rig.interrupt()
        if !denyBeforePause {
            _ = try await host.host.deny(rig.target.id)
        }
        let admitted = host.sink.segmentCount
        let before = try await callPolicyAudioFrames(rig.socket).count
        #expect(await host.refusals == 0)
        rig.interruptionEnded()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        try rig.capture.yield(callPolicyBuffer(frames: 19_200))
        try await rig.finishRefusal(gate: host.sendGate, before: before)
        let attempts = await host.resumedAttempts
        let refusals = await host.refusals
        #expect(attempts == 1 && refusals == 1)
        #expect(host.sink.segmentCount == admitted)
        await rig.close()
    }
}

extension AmbientCallPolicyAdmissionTests {
    @Test func deliveredGatePolicyStopWhilePausedVetoesAdmission() async throws {
        let rig = try CallPolicyHostRig()
        let host = try await CallPolicyHost.make(base: rig.socket, target: rig.target.id)
        rig.transport = host
        try await rig.start()
        try rig.feed()
        await host.awaitInput()
        try await rig.interrupt()
        let before = try await callPolicyAudioFrames(rig.socket).count
        _ = try await host.host.deny(rig.target.id)
        // Model a pre-call segment's delayed policy result, without new device PCM during the pause.
        try await host.refuseRetainedStream()
        try await rig.noticeProcessed()
        rig.interruptionEnded()
        await rig.microphoneRetry.fire()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        try await callPolicyEventually { await MainActor.run {
            !rig.controller.isOn || rig.capture.startCount > 1
        } }
        #expect(!rig.controller.isOn && !rig.controller.isListening && rig.controller.pausedReason == nil)
        #expect(!rig.controller.reconnect.canResumeCapture && !rig.controller.reconnect.isPending)
        #expect(rig.capture.startCount == 1 && rig.capture.stopCount >= 1)
        #expect(rig.controller.stopReason == "listening stopped: target policy changed during call")
        #expect(rig.unexpected.last == rig.controller.stopReason || rig.notices.last?.text == rig.controller.stopReason)
        #expect(try await callPolicyAudioFrames(rig.socket).count == before)
        #expect(await rig.connector.opens == 1)
        #expect(await rig.retry.pending == 0)
        await rig.close()
    }

    @Test(arguments: ["ambient stopped: synthetic", "ambient unavailable: synthetic"])
    func transientRefusalWhilePausedStillAdmitsResume(message: String) async throws {
        let rig = try CallPolicyHostRig()
        let host = try await CallPolicyHost.make(base: rig.socket, target: rig.target.id)
        rig.transport = host
        try await rig.start()
        try rig.feed()
        await host.awaitInput()
        try await rig.interrupt()
        try await rig.socket.push(.error(code: .notAllowed, message: message))
        try await rig.socket.push(.targets([callPolicyBarrier]))
        try await rig.noticeProcessed()
        let admitted = host.sink.segmentCount
        rig.interruptionEnded()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        #expect(rig.controller.isOn && rig.controller.isListening && rig.capture.startCount == 2)
        #expect(rig.controller.stopReason == nil)
        try rig.feed()
        try await callPolicyEventually {
            let attempts = await host.resumedAttempts
            return attempts == 1 && host.sink.segmentCount > admitted
        }
        await rig.close()
    }
}
