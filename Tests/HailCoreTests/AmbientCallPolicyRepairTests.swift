import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #1034: adversarial refusal delivery uses the store's notice path and real scripted socket ordering.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientCallPolicyRepairTests {
    @Test(arguments: ["ambient target_policy_changed", "ambient target is not allowed"])
    func policyVetoAtAwaitedConstructorReturnCannotStartCapture(message: String) async throws {
        try await withCallPolicyRepairRig { rig in
            try await rig.start()
            try await rig.feed()
            try await waitUntil { try await !audioFrames(rig.socket).isEmpty }
            let frame = try #require(try await audioFrames(rig.socket).last)
            let stream: UUID
            if case .audio(let audio) = frame.payload { stream = try #require(audio.streamID) } else {
                Issue.record("Audio frame fixture lost its payload")
                throw CancellationError()
            }
            let binding = try rig.currentBinding()
            try await pauseForPolicyRepair(rig)
            let sent = try await audioFrames(rig.socket).count
            let gate = SleepGate()
            rig.activationGate = gate
            var delivered = false
            rig.beforeMakeStreamerReturn = {
                // A notice callback is synchronous on MainActor. Deliver after the constructor's await,
                // before it returns, so asynchronous end() has not established a new session yet.
                let event = HostReplyEvent(endpointID: rig.endpoint.id, frame: Frame(timestamp: 1,
                    target: binding.targetID, source: "haild",
                    payload: .control(.error(code: .notAllowed, message: message))))
                delivered = HostNoticeOrigin.$generation.withValue(binding.connectionGeneration) {
                    HostNoticeOrigin.$streamID.withValue(stream) { rig.store.receiveAmbientNotice(event) }
                }
                #expect(!rig.controller.reconnect.canResumeCapture)
            }
            let resuming = Task { @MainActor in await rig.controller.update(binding: binding, scene: .active) }
            defer { resuming.cancel() }
            try await waitUntil { await gate.isWaiting() }
            #expect(rig.makeCalls == 2 && rig.capture.startCount == 1)
            await gate.fire()
            try await ambientRefusalDeadline { await resuming.value }
            #expect(delivered)
            try await waitUntil { @MainActor in !rig.controller.isOn && rig.released == 2 }
            for _ in 0..<6 { try rig.capture.yield(sineBuffer()) }
            #expect(rig.capture.startCount == 1 && !rig.controller.isListening)
            #expect(rig.controller.stopReason == AmbientRefusal.callPolicyStopReason)
            #expect(try await audioFrames(rig.socket).count == sent)
            #expect(!rig.controller.reconnect.isPending && !rig.controller.reconnect.canResumeCapture)
        }
    }

    @Test func explicitlyDifferentTargetNoticeCannotPoisonThePausedStream() async throws {
        try await withCallPolicyRepairRig { rig in
            try await rig.start()
            try await rig.feed()
            try await waitUntil { try await !audioFrames(rig.socket).isEmpty }
            try await pauseForPolicyRepair(rig)
            try await deliverAddressedPolicyNotice(target: "tmux:previous", to: rig)
            #expect(rig.controller.isOn && rig.controller.pausedReason != nil)
            #expect(rig.controller.reconnect.canResumeCapture && rig.controller.stopReason == nil)
            await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
            #expect(rig.capture.startCount == 2 && rig.controller.isListening)
            let before = try await audioFrames(rig.socket).count
            try await rig.feed()
            try await waitUntil { try await audioFrames(rig.socket).count > before }
            #expect(rig.controller.isOn && rig.controller.stopReason == nil)
        }
    }

    @Test(arguments: [false, true])
    func previousSelectionStreamCannotVetoANewPausedRun(sameTarget: Bool) async throws {
        try await withCallPolicyRepairRig { rig in
            try await rig.start()
            try await rig.feed()
            try await waitUntil { try await !audioFrames(rig.socket).isEmpty }
            let old = try rig.currentBinding()
            await rig.controller.turnOff()
            let target = sameTarget ? rig.target
                : TargetInfo(id: "tmux:second", kind: "tmux", name: "Second", alive: true)
            try await rig.socket.push(.targets([rig.target, target]))
            try await waitUntil { @MainActor in rig.store.snapshots[rig.endpoint.id]?.targets.contains(target) == true }
            try await rig.select(restoring: false, targetID: target.id)
            let fresh = try #require(rig.store.ambientBinding(host: rig.endpoint.id, targetID: target.id))
            #expect(fresh.selection != old.selection)
            await rig.controller.turnOn(for: fresh)
            try await pauseForPolicyRepair(rig)
            // No PCM from this capture: HostConnection still attributes a legacy target-less notice to
            // the previous stream. It must not be treated as proof for the new paused microphone run.
            try await deliverAddressedPolicyNotice(target: nil, to: rig)
            #expect(rig.controller.isOn && rig.controller.pausedReason != nil)
            #expect(rig.controller.reconnect.canResumeCapture && rig.controller.stopReason == nil)
            // Restore the full target list after the observable notice barrier.
            try await rig.socket.push(.targets([rig.target, target]))
            try await waitUntil { @MainActor in rig.store.ambientBinding(host: rig.endpoint.id,
                                                                        targetID: target.id) == fresh }
            await rig.controller.update(binding: fresh, scene: .active)
            #expect(rig.capture.startCount == 3 && rig.controller.isListening)
            let before = try await audioFrames(rig.socket).count
            try await rig.feed()
            try await waitUntil { try await audioFrames(rig.socket).count > before }
            #expect(rig.controller.isOn && rig.controller.stopReason == nil)
        }
    }
}
