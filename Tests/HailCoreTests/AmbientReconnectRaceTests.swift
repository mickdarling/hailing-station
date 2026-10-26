import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectRaceTests {
    @Test func audioSeesTransportCloseBeforeReceiveLoopPublishesIt() async throws {
        let rig = try AmbientReconnectRig()
        let closing = AmbientClosingSocket(base: rig.socket)
        rig.transport = closing
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { await closing.gate.isWaiting() }
        #expect(rig.store.snapshots[rig.endpoint.id]?.state == .ready)
        for index in 0..<3 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { await MainActor.run { rig.controller.reconnect.isPending } }
        // A still-ready snapshot or selection callback on the OLD generation must not consume the intent.
        await rig.controller.reconnect.restore(controller: rig.controller, store: rig.store)
        #expect(rig.notices.isEmpty)
        #expect(rig.capture.startCount == 1)
        await closing.gate.fire()
        try await waitUntil { await rig.retry.isWaiting() }
        try await rig.reconnect()
        #expect(rig.controller.isListening)
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }

    @Test func oldStreamFailureCannotArmRecoveryForNewListening() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let binding = try rig.currentBinding()
        for index in 0..<3 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { try await rig.socket.sentFrames().contains { if case .audio = $0.payload {
            return true
        }; return false } }
        let oldAudio = try #require(try await rig.socket.sentFrames().compactMap { frame -> AudioPayload? in
            if case .audio(let audio) = frame.payload { return audio }; return nil
        }.first)
        await rig.controller.turnOff()
        await rig.controller.turnOn(for: binding)
        rig.controller.reconnect.sendFailed(SocketTestError.closed, audio: oldAudio, binding: binding,
                                             controller: rig.controller, store: rig.store)
        #expect(!rig.controller.reconnect.isPending)
        #expect(rig.controller.isListening)
        await rig.close()
    }

    @Test func overlappingReauthorizationsOnlyPublishNewestConfirmation() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        let count = try await rig.socket.sentFrames().count
        let first = Task { try await rig.store.selectTarget(host: rig.endpoint.id,
                                                           targetID: rig.target.id, restoring: true) }
        try await waitUntil { try await rig.selectionPing(after: count) != nil }
        let firstPing = try #require(try await rig.selectionPing(after: count))
        let secondCount = try await rig.socket.sentFrames().count
        let second = Task { try await rig.store.selectTarget(host: rig.endpoint.id,
                                                            targetID: "tmux:other", restoring: true) }
        try await waitUntil { try await rig.selectionPing(after: secondCount) != nil }
        let secondPing = try #require(try await rig.selectionPing(after: secondCount))
        try await rig.socket.push(.pong(nonce: firstPing))
        try await first.value
        #expect(rig.store.ambientBinding(host: rig.endpoint.id, targetID: rig.target.id) == nil)
        try await rig.socket.push(.pong(nonce: secondPing))
        try await second.value
        #expect(rig.store.ambientBinding(host: rig.endpoint.id, targetID: "tmux:other") != nil)
        await rig.close()
    }

    @Test(arguments: [ControlPayload.duckMode(on: true), .mediaMode(on: true)])
    func modeEntryThenExitDuringGapStillBlocksRestore(mode: ControlPayload) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false, mode: mode)
        let privacy = mode == .duckMode(on: true)
        try await rig.socket.push(privacy ? .duckMode(on: false) : .mediaMode(on: false))
        try await rig.select(restoring: true)
        try await rig.expectStopped(privacy ? .privacy : .modeChanged)
        await rig.close()
    }

    @Test(arguments: [true, false]) func ownerOrPrivacyChangeDuringActivationWins(ownerStop: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let gate = SleepGate()
        rig.activationGate = gate
        let restarting = Task { try await rig.reconnect() }
        try await waitUntil { await gate.isWaiting() }
        if ownerStop { await rig.controller.turnOff() } else {
            try await rig.store.setPrivacy(on: true, host: rig.endpoint.id)
        }
        await gate.fire()
        try await restarting.value
        try await rig.expectStopped(ownerStop ? .ownerStop : .privacy)
        #expect(rig.makeCalls == 2)
        await rig.close()
    }

    @Test func explicitDisconnectDuringGapBlocksRecoveryAndReportsStopped() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        await rig.store.disconnect(rig.endpoint.id)
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: rig.endpoint.url)
        await rig.store.connect(rig.endpoint.id)
        await rig.retry.fire()
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        try await rig.expectStopped(.explicitDisconnect)
        await rig.close()
    }
}

/// Suspends physical close so audio can observe the socket's loss before the state observer does.
private actor AmbientClosingSocket: WebSocketTransport {
    let base: ScriptedSocket
    let gate = SleepGate()
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws { await base.send(data) }
    func receive() async throws -> Data { try await base.receive() }
    func close() async {
        try? await gate.sleep(.zero)
        await base.close()
    }
}
