import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectSocketIdentityTests {
    @Test func sameSocketSendAndReceiveLossCountOnceAndDifferentSocketFlaps() async throws {
        let rig = try AmbientReconnectRig()
        let first = IdentityLossSocket(base: rig.socket)
        rig.transport = first
        try await rig.start()
        let original = try #require(rig.store.snapshots[rig.endpoint.id]?.connectionGeneration)
        do {
            try await rig.store.sendAudio(ambientSegment(), to: rig.currentBinding())
        } catch {
            #expect(error is URLError)
        }
        #expect(await first.sendLosses == 1)
        #expect(rig.controller.reconnect.isPending && rig.notices.isEmpty)
        await rig.socket.fail()
        try await waitUntil { await rig.retry.isWaiting() }
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
}

private actor IdentityLossSocket: WebSocketTransport {
    let base: ScriptedSocket
    private(set) var sendLosses = 0
    private(set) var receiveLosses = 0
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws {
        if case .audio = try FrameCoding.decode(data).payload {
            sendLosses += 1
            throw URLError(.networkConnectionLost)
        }
        await base.send(data)
    }
    func receive() async throws -> Data {
        do { return try await base.receive() } catch {
            receiveLosses += 1
            throw error
        }
    }
    func close() async { await base.close() }
}
