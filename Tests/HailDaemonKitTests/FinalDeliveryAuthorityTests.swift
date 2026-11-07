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
            await #expect(throws: PolicyFileError.unwritable("synthetic persistence")) {
                try await rig.host.deny(FinalDeliveryRig.target)
            }
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
        #expect(rig.listener.lastInput.latest(for: FinalDeliveryRig.target)?.connection == rig.session.connectionID)
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
}
