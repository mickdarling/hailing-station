import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Tighten final delivery authority checks at the adapter handoff.
@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct FinalDeliveryAuthorityTests {
    enum Transport: CaseIterable { case peer, listener }
    enum Boundary: CaseIterable { case registry, adapter }
    enum Reply: CaseIterable { case lease, permit, lifetime, clock }

    @Test(arguments: Transport.allCases, Boundary.allCases)
    func finalTransportAuthority(_ transport: Transport, _ boundary: Boundary) async throws {
        let rig = try await FinalDeliveryRig.make()
        let barrier = boundary == .registry ? rig.adapter.listing : rig.adapter.handoff
        await barrier.arm()
        let delivery = Task { try await rig.ambient() }
        await barrier.wait()
        switch transport {
        case .peer: await rig.peer.finish(reason: "synthetic completion")
        case .listener: await rig.listener.stop(reason: "synthetic completion")
        }
        await barrier.resume()
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await delivery.value }
        await rig.expectEmpty()
        await rig.listener.stop(reason: "synthetic completion")
    }

    @Test(arguments: Reply.allCases)
    func finalReplyAuthority(_ reply: Reply) async throws {
        let rig = try await FinalDeliveryRig.make()
        await rig.adapter.handoff.arm()
        let delivery = Task { try await rig.ambient() }
        await rig.adapter.handoff.wait()
        #expect(await rig.session.replyRequests.count == 1)
        switch reply {
        case .lease: rig.adapter.leaseAuthority.invalidate()
        case .permit:
            let generation = await rig.host.inputPolicyGeneration(for: FinalDeliveryRig.target)
            await rig.host.revokeAuthority()
            try generation.requireCurrent()
        case .lifetime: rig.clock.advance(120_000)
        case .clock: rig.clock.advance(-1)
        }
        await rig.adapter.handoff.resume()
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await delivery.value }
        await rig.expectEmpty()
        await rig.listener.stop(reason: "synthetic completion")
    }

    @Test func currentFinalAuthority() async throws {
        let rig = try await FinalDeliveryRig.make()
        await rig.adapter.handoff.arm()
        let delivery = Task { try await rig.ambient() }
        await rig.adapter.handoff.wait()
        await rig.adapter.handoff.resume()
        let owner = try #require(try await delivery.value)
        #expect(await rig.adapter.deliveries == ["synthetic input"])
        #expect(await rig.adapter.contexts.map(\.id) == [owner])
        #expect(await rig.session.replyRequests[owner]?.committed == true)
        let ledger = await rig.listener.lastInput, connection = await rig.session.connectionID
        #expect(ledger.latest(for: FinalDeliveryRig.target)?.connection == connection)
        await rig.listener.stop(reason: "synthetic completion")
    }

    @Test func currentLocalDispatchAuthority() async throws {
        let rig = try await FinalDeliveryRig.make()
        let owner = try #require(try await rig.listener.dispatch(dispatchRequest(
            connection: rig.id, target: FinalDeliveryRig.target, binding: "synthetic-binding"
        )))
        #expect(await rig.adapter.contexts.map(\.id) == [owner])
        #expect(await rig.session.replyRequests[owner]?.committed == true)
        await rig.listener.stop(reason: "synthetic completion")
    }

    @Test(arguments: [119_999, 120_000])
    func finalLegacyAuthority(_ elapsed: Int64) async throws {
        let rig = try await FinalDeliveryRig.make(legacy: true)
        let reference = UUID()
        await rig.adapter.handoff.arm()
        let delivery = Task { try await rig.ambient(reference: reference) }
        await rig.adapter.handoff.wait()
        rig.clock.advance(elapsed)
        await rig.adapter.handoff.resume()
        if elapsed < 120_000 {
            #expect(try await delivery.value == reference)
            #expect(await rig.adapter.deliveries == ["synthetic input"])
            #expect(await rig.session.replyRequests[reference]?.committed == true)
        } else {
            await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await delivery.value }
            await rig.expectEmpty()
        }
        await rig.listener.stop(reason: "synthetic completion")
    }

    @Test func currentTextAuthority() async throws {
        let rig = try await FinalDeliveryRig.make()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host,
                                             authorizer: PersonalTerminalAuthorizer())
        let pair = try await FallbackSocketPair.connect(port: listener.start(), selecting: [FinalDeliveryRig.target])
        defer { pair.close() }
        try await recipientSocketSend(sessionFrame(
            target: FinalDeliveryRig.target, payload: .text(TextPayload(text: "synthetic input"))
        ), on: pair.sockets[0])
        try await pair.barrier()
        #expect(await rig.adapter.deliveries == ["synthetic input"])
        #expect(await rig.adapter.contexts.count == 1)
        await listener.stop(reason: "synthetic completion")
        await rig.listener.stop(reason: "synthetic completion")
    }
}
