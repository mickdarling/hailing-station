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
func assertPolicyStopped(_ rig: CallReconnectRig, starts: Int) async throws {
    #expect(!rig.controller.isOn && !rig.controller.isListening && rig.controller.pausedReason == nil)
    #expect(!rig.controller.reconnect.isPending && rig.capture.startCount == starts)
    #expect(rig.controller.stopReason == "listening stopped: target policy changed during call")
    #expect(rig.unexpected.last == rig.controller.stopReason || rig.notices.last?.text == rig.controller.stopReason)
    #expect(rig.capture.stopCount >= starts)
    #expect(!(await rig.retry.isWaiting()))
}

actor CallPolicyRefusingSocket: WebSocketTransport {
    let base: ScriptedSocket
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
        }
    }

    func receive() async throws -> Data {
        try await base.receive()
    }

    func close() async {
        await base.close()
    }
}
