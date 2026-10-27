import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectLateDropTests {
    // P2: a flap after reauthorization emits a terminal "stopped, tap to resume" notice while capture continues.
    @Test func interruptedAttemptNoticeDoesNotTellArmedOwnerToTap() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await rig.select(restoring: true)
        try await rig.drop()
        let interim = rig.notices
        #expect(rig.controller.isOn && rig.capture.stopCount == 0)
        try await rig.reconnect()
        #expect(!(interim.last?.text.contains("listening stopped") == true && rig.controller.isOn),
                "The owner was told listening stopped while capture stayed armed and later resumed with no tap")
        #expect(interim.map(\.outcome) == [.interrupted])
        #expect(interim.last?.text == "Connection dropped again; still reconnecting")
        #expect(rig.notices.map(\.outcome) == [.interrupted, .applied])
        #expect(Set(rig.notices.map(\.id)).count == 2)
        await rig.close()
    }

    // P3: an old-generation audio send that fails only after the replacement connection is ready.
    @Test func lateOldGenerationSendFailureDoesNotCreateAnotherDrop() async throws {
        let rig = try AmbientReconnectRig()
        let held = HeldOldAmbientSocket(base: rig.socket)
        rig.transport = held
        try await rig.start()
        for index in 0..<6 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { await held.heldCount() > 0 }
        let oldGeneration = rig.store.snapshots[rig.endpoint.id]?.connectionGeneration
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        #expect(rig.store.snapshots[rig.endpoint.id]?.connectionGeneration != oldGeneration)
        await held.failHeld()
        try await Task.sleep(for: .milliseconds(200))
        // A real host answers every selection round trip, including the one a spurious flap re-issues.
        let answered = AnsweredAmbientPings()
        try await waitUntil {
            let frames = try await rig.socket.sentFrames()
            for frame in frames {
                guard case .control(.ping(let nonce)) = frame.payload else { continue }
                if await answered.insert(nonce) { try await rig.socket.push(.pong(nonce: nonce)) }
            }
            return await MainActor.run {
                rig.store.ambientBinding(host: rig.endpoint.id, targetID: rig.target.id) != nil
                    || !rig.controller.reconnect.isPending
            }
        }
        if rig.controller.isOn { try await rig.feed() }
        #expect(rig.notices.map(\.outcome) == [.applied], "One drop produced more than one notice")
        await rig.close()
    }
}

private actor HeldOldAmbientSocket: WebSocketTransport {
    let base: ScriptedSocket
    private var held: [CheckedContinuation<Void, any Error>] = []
    private var holding = true
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws {
        if case .audio = try FrameCoding.decode(data).payload, holding {
            try await withCheckedThrowingContinuation { held.append($0) }
            return
        }
        await base.send(data)
    }
    func heldCount() -> Int { held.count }
    func failHeld() {
        holding = false
        held.forEach { $0.resume(throwing: SocketTestError.closed) }
        held.removeAll()
    }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
}

private actor AnsweredAmbientPings {
    private var seen = Set<String>()
    func insert(_ nonce: String) -> Bool { seen.insert(nonce).inserted }
}
