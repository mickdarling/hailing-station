import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientCallPolicyTests {
    @Test func policyChangedRefusalDuringPauseVetoesResume() async throws {
        try await refusalDuringPause("ambient target_policy_changed")
    }

    @Test func notAllowedRefusalDuringPauseVetoesResume() async throws {
        try await refusalDuringPause("ambient target is not allowed — run haild targets allow on the Mac")
    }

    private func refusalDuringPause(_ message: String) async throws {
        let rig = try CallReconnectRig()
        try await rig.start()
        try await rig.feed()
        try await callEventually { try await !audioFrames(rig.socket).isEmpty }
        try await rig.interrupt()
        let sent = try await audioFrames(rig.socket).count
        try await deliverPolicyNotice(message, to: rig)
        rig.interruptionEnded()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        await rig.microphoneRetry.release()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        try await assertPolicyStopped(rig, starts: 1)
        #expect(try await audioFrames(rig.socket).count == sent)
        await rig.close()
    }

    @Test(arguments: ["ambient stopped: synthetic", "ambient unavailable: synthetic"])
    func transientRefusalDuringPauseStillResumes(message: String) async throws {
        let rig = try CallReconnectRig()
        try await rig.start()
        try await rig.feed()
        try await callEventually { try await !audioFrames(rig.socket).isEmpty }
        try await rig.interrupt()
        try await deliverPolicyNotice(message, to: rig)
        rig.interruptionEnded()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        #expect(rig.controller.isOn && rig.controller.isListening && rig.capture.startCount == 2)
        #expect(rig.controller.stopReason == nil)
        await rig.close()
        await rig.microphoneRetry.release()
    }
}

extension AmbientCallPolicyTests {
    @Test func policyRefusalBeforeAnyAudioStillVetoesPausedCall() async throws {
        let rig = try CallReconnectRig()
        try await rig.start()
        let binding = try rig.currentBinding()
        try await rig.interrupt()
        try await rig.socket.push(.error(code: .notAllowed, message: "ambient target_policy_changed"))
        try await callEventually { await MainActor.run {
            if case .failed = rig.store.snapshots[rig.endpoint.id]?.state {
                return true
            }
            return false
        } }
        rig.interruptionEnded()
        await rig.controller.update(binding: binding, scene: .active)
        await rig.microphoneRetry.release()
        try await assertPolicyStopped(rig, starts: 1)
        #expect(try await audioFrames(rig.socket).isEmpty)
        await rig.close()
    }
}
