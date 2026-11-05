import Foundation
import HailProtocol
import Testing
@testable import HailCore

let callPolicyBarrier = TargetInfo(id: "tmux:synthetic", kind: "tmux", name: "Refusal processed", alive: true)

extension CallPolicyHostRig {
    func finishRefusal(gate: CallPolicySignal, before: Int) async throws {
        try await noticeProcessed()
        await gate.fire()
        try await callPolicyEventually {
            let waiting = await self.microphoneRetry.pending > 0
            return await MainActor.run { !self.controller.isOn || waiting }
        }
        try await assertStopped()
        if !controller.isOn {
            try await callPolicyEventually { await MainActor.run { self.released == 2 } }
        }
        await microphoneRetry.fire()
        await controller.update(binding: try currentBinding(), scene: .active)
        interruptionEnded()
        for _ in 0..<6 {
            try capture.yield(callPolicyBuffer())
        }
        #expect(try await callPolicyAudioFrames(socket).count == before + 1)
        #expect(!controller.isOn && capture.startCount == 2)
        #expect(await retry.pending == 0)
    }

    func noticeProcessed() async throws {
        try await callPolicyEventually { await MainActor.run {
            self.store.snapshots[self.endpoint.id]?.targets == [callPolicyBarrier]
        } }
    }

    private func assertStopped() async throws {
        try await callPolicyEventually { await MainActor.run { !self.controller.isOn } }
        #expect(!controller.isListening && controller.pausedReason == nil)
        #expect(!controller.reconnect.isPending && capture.startCount == 2)
        let reason = controller.stopReason ?? ""
        #expect(reason.contains("target policy changed") || reason.contains("ambient target is not allowed"))
        #expect(unexpected.last == controller.stopReason || notices.last?.text == controller.stopReason)
        #expect(capture.stopCount >= 2)
        #expect(await retry.pending == 0)
        #expect(await connector.opens == 1)
        #expect(store.ambientBinding(host: endpoint.id, targetID: target.id)?.targetID == target.id)
    }
}
