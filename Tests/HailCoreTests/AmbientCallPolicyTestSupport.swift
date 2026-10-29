import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
func deliverPolicyNotice(_ message: String, to rig: CallReconnectRig) async throws {
    try await rig.socket.push(.error(code: .notAllowed, message: message))
    // The receive loop serializes the refusal and this observable barrier.
    let barrier = TargetInfo(id: "tmux:barrier", kind: "tmux", name: "Barrier", alive: true)
    try await rig.socket.push(.targets([rig.target, barrier]))
    try await callEventually { await MainActor.run {
        rig.store.snapshots[rig.endpoint.id]?.targets.contains(barrier) == true
    } }
}

@MainActor
func assertPolicyStopped(_ rig: CallReconnectRig, starts: Int, resumed: Bool = false) async throws {
    try await callEventually { await MainActor.run {
        !rig.controller.isOn || rig.capture.startCount > starts
    } }
    #expect(!rig.controller.isOn && !rig.controller.isListening && rig.controller.pausedReason == nil)
    #expect(!rig.controller.reconnect.isPending && rig.capture.startCount == starts)
    if resumed {
        let reason = rig.controller.stopReason ?? ""
        #expect(reason.contains("target policy changed") || reason.contains("ambient target is not allowed"))
    } else {
        #expect(!rig.controller.reconnect.canResumeCapture)
        #expect(rig.controller.stopReason == "listening stopped: target policy changed during call")
    }
    #expect(rig.unexpected.last == rig.controller.stopReason || rig.notices.last?.text == rig.controller.stopReason)
    #expect(rig.capture.stopCount >= starts)
    #expect(!(await rig.retry.isWaiting()))
    #expect(await rig.connector.openCount(for: rig.endpoint.url) == 1)
    if rig.store.snapshots[rig.endpoint.id]?.state == .ready {
        #expect(rig.store.selectedTargets[rig.endpoint.id] == rig.target.id)
    }
}

actor CallPolicyRefusingSocket: WebSocketTransport {
    let base: ScriptedSocket
    let sendGate = SleepGate()
    private(set) var resumedAttempts = 0
    private(set) var refused = false

    init(base: ScriptedSocket) {
        self.base = base
    }

    func send(_ data: Data) async throws {
        let frame = try FrameCoding.decode(data)
        await base.send(data)
        if case .audio(let audio) = frame.payload, audio.isResume {
            resumedAttempts += 1
            refused = true
            try await base.push(.error(code: .notAllowed, message: "ambient target is not allowed"))
            try await base.push(.targets([callPolicyBarrier]))
            if resumedAttempts == 1 {
                try await sendGate.sleep(.zero)
            }
        }
    }

    func receive() async throws -> Data {
        try await base.receive()
    }

    func close() async {
        await base.close()
    }
}

let callPolicyBarrier = TargetInfo(id: "tmux:synthetic", kind: "tmux", name: "Refusal processed", alive: true)

@MainActor
func finishCallPolicyRefusal(_ rig: CallReconnectRig, gate: SleepGate, before: Int) async throws {
    try await callEventually { await MainActor.run {
        rig.store.snapshots[rig.endpoint.id]?.targets == [callPolicyBarrier]
    } }
    await gate.fire()
    try await callEventually {
        let waiting = await rig.microphoneRetry.pending > 0
        return await MainActor.run { !rig.controller.isOn || waiting }
    }
    try await assertPolicyStopped(rig, starts: 2, resumed: true)
    if !rig.controller.isOn {
        try await callEventually { await MainActor.run { rig.released == 2 } }
    }
    await rig.microphoneRetry.release()
    await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
    rig.interruptionEnded()
    for _ in 0..<6 {
        try rig.capture.yield(sineBuffer())
    }
    #expect(try await audioFrames(rig.socket).count == before + 1)
    #expect(!rig.controller.isOn && rig.capture.startCount == 2)
    #expect(!(await rig.retry.isWaiting()))
}
