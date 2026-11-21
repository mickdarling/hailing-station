import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectSocketIdentityTests {
    @Test func sameSocketSendAndReceiveLossCountOnceAndDifferentSocketFlaps() async throws {
        let rig = try AmbientReconnectRig()
        rig.socket = ScriptedSocket(finishReceiveOnClose: false)
        let first = IdentityLossSocket(base: rig.socket)
        rig.transport = first
        try await rig.start()
        let original = try #require(rig.store.snapshots[rig.endpoint.id]?.connectionGeneration)
        await first.receiveAfterPong.wait()
        try rig.capture.yield(sineBuffer(frames: 14_400))
        for await _ in rig.retry.firstSleep.stream {}
        #expect(await first.sendLosses == 1)
        #expect(await first.receiveLosses == 0)
        #expect(rig.controller.reconnect.isPending && rig.notices.isEmpty)
        await rig.socket.fail()
        await first.receiveFailed.wait()
        #expect(await first.receiveLosses == 1)
        #expect(rig.controller.reconnect.isPending && rig.notices.isEmpty)
        // The new socket remains in selection confirmation, so recovery is still pending at its drop.
        try await rig.reconnect(selectTarget: false)
        let next = try #require(rig.store.snapshots[rig.endpoint.id]?.connectionGeneration)
        #expect(next != original)
        try await rig.drop()
        #expect(rig.notices.map(\.outcome) == [.interrupted])
        #expect(rig.controller.reconnect.isPending && rig.controller.isListening)
        #expect(rig.capture.startCount == 1)
        await rig.close()
    }

    @Test func refusalOnReplacementSocketAfterSendLossRevisesAppliedNotice() async throws {
        let rig = try AmbientReconnectRig()
        let first = IdentityLossSocket(base: rig.socket)
        rig.transport = first
        try await rig.start()
        await first.receiveAfterPong.wait()
        try rig.capture.yield(sineBuffer(frames: 14_400))
        for await _ in rig.retry.firstSleep.stream {}
        #expect(await first.sendLosses == 1)
        try await rig.reconnect()
        let applied = try #require(rig.controller.reconnect.notice)
        try #require(applied.outcome == .applied)
        try await rig.waitForAcceptancePing()
        try await rig.socket.push(.error(code: .notAllowed, message: "ambient moved to pad"))
        await arrivalObserved { !rig.controller.isOn }
        let handoff = AmbientHandoff.movedAway(to: "pad")
        #expect(!rig.controller.isListening && rig.controller.handoff == handoff)
        #expect(rig.controller.stopReason == handoff.status && rig.unexpected.isEmpty)
        #expect(rig.notices.map(\.id) == [applied.id, applied.id])
        #expect(rig.notices.last?.outcome == .failed && rig.notices.last?.reason == .movedAway)
        await rig.close()
    }
}

private actor IdentityLossSocket: WebSocketTransport {
    let base: ScriptedSocket
    private(set) var sendLosses = 0
    private(set) var receiveLosses = 0
    private var sawPong = false
    let receiveAfterPong = OpenGate()
    let receiveFailed = OpenGate()
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws {
        if case .audio = try FrameCoding.decode(data).payload {
            sendLosses += 1
            throw URLError(.networkConnectionLost)
        }
        await base.send(data)
    }
    func receive() async throws -> Data {
        if sawPong { await receiveAfterPong.release() }
        do {
            let data = try await base.receive()
            if case .control(.pong) = try FrameCoding.decode(data).payload { sawPong = true }
            return data
        } catch {
            receiveLosses += 1
            await receiveFailed.release()
            throw error
        }
    }
    func close() async { await base.close() }
}
