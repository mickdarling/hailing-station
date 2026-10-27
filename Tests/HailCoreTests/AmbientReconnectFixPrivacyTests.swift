import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectFixPrivacyTests {
    @Test func unconfirmedOwnerPrivacyTapBlocksRestoreAtDrop() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.store.setPrivacy(on: true, host: rig.endpoint.id)
        #expect(rig.store.privacyLocal[rig.endpoint.id]?.request?.on == true)
        try await rig.drop()
        try await rig.expectStopped(.privacy)
        try await rig.reconnect()
        try await rig.expectNoRestoredPCM()
        #expect(rig.notices.count == 1)
        await rig.close()
    }

    @Test func staleGenerationCannotSettlePendingOwnerPrivacyTap() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.store.setPrivacy(on: true, host: rig.endpoint.id)
        let request = rig.store.privacyLocal[rig.endpoint.id]?.request
        let stale = UUID()
        let event = HostReplyEvent(endpointID: rig.endpoint.id, frame: Frame(
            timestamp: 1, source: "Synthetic", payload: .control(.duckMode(on: true, reason: "device"))
        ))
        HostNoticeOrigin.$generation.withValue(stale) { #expect(rig.store.receiveAmbientNotice(event)) }
        #expect(rig.store.privacyLocal[rig.endpoint.id]?.request == request)
        #expect(rig.store.duckMode[rig.endpoint.id] == nil)
        try await rig.drop()
        try await rig.expectStopped(.privacy)
        try await rig.reconnect()
        try await rig.expectNoRestoredPCM()
        await rig.close()
    }

    @Test func earlyConfirmationWaitsForSuccessfulReassertSend() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        let origin = try rig.currentBinding().connectionGeneration
        try await rig.drop()
        let base = ScriptedSocket()
        let held = AmbientSuccessfulHeldPrivacySocket(base: base)
        rig.socket = base
        await rig.connector.enqueue(.socket(held), for: rig.endpoint.url)
        await rig.retry.fire()
        try await rig.handshake(base)
        try await rig.confirmAutomaticSelection()
        try await waitUntil { await held.gate.isWaiting() }
        let old = rig.controller.binding
        let event = HostReplyEvent(endpointID: rig.endpoint.id, frame: Frame(
            timestamp: 1, source: "Synthetic", payload: .control(.duckMode(on: true, reason: "device"))
        ))
        HostNoticeOrigin.$generation.withValue(origin) { #expect(rig.store.receiveAmbientNotice(event)) }
        #expect(rig.store.duckMode[rig.endpoint.id] == nil)
        try await base.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.on == true } }
        #expect(rig.controller.binding == old && rig.controller.reconnect.isPending)
        try rig.discardWhileWaiting()
        try await rig.expectNoRestoredPCM()
        await held.gate.fire()
        try await waitUntil { await MainActor.run { rig.controller.binding != old } }
        try await rig.feed()
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }
}

private actor AmbientSuccessfulHeldPrivacySocket: WebSocketTransport {
    let base: ScriptedSocket
    let gate = SleepGate()
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws {
        if try FrameCoding.decode(data).payload == .control(.setPrivacy(on: true)) {
            try await gate.sleep(.zero)
        }
        await base.send(data)
    }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
}
