import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Held Send carries the same final delivery authority at the adapter handoff.
@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct FinalDeliveryHeldAuthorityTests {
    @Test(arguments: FinalDeliveryAuthorityTests.Transport.allCases)
    func finalTransportAuthority(_ transport: FinalDeliveryAuthorityTests.Transport) async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let held = try await rig.hold()
        await rig.adapter.handoff.arm()
        let delivery = Task { await rig.listener.sendHeld(held, from: rig.session.connectionID) }
        await rig.adapter.handoff.wait()
        switch transport {
        case .peer: await rig.peer.finish(reason: "synthetic completion")
        case .listener: await rig.listener.stop(reason: "synthetic completion")
        }
        await rig.adapter.handoff.resume()
        guard case .refused = await delivery.value else {
            Issue.record("final transport authority must remain current")
            return
        }
        await rig.expectEmpty()
        #expect(await rig.host.heldRequests.entries[held] != nil)
        await rig.listener.stop(reason: "synthetic completion")
    }

    @Test(arguments: FinalDeliveryAuthorityTests.Reply.allCases)
    func finalReplyAuthority(_ reply: FinalDeliveryAuthorityTests.Reply) async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let held = try await rig.hold()
        await rig.adapter.handoff.arm()
        let delivery = Task { await rig.listener.sendHeld(held, from: rig.session.connectionID) }
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
        #expect(await delivery.value == .refused(.denied))
        await rig.expectEmpty()
        #expect(await rig.host.heldRequests.entries[held] != nil)
        await rig.listener.stop(reason: "synthetic completion")
    }

    @Test func finalHeldNoticeAuthority() async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let held = try await rig.hold()
        rig.clock.advance(119_999)
        await rig.adapter.handoff.arm()
        let delivery = Task { await rig.listener.sendHeld(held, from: rig.session.connectionID) }
        await rig.adapter.handoff.wait()
        rig.clock.advance(1)
        await rig.adapter.handoff.resume()
        #expect(await delivery.value == .refused(.denied))
        await rig.expectEmpty()
        #expect(await rig.host.heldRequests.entries[held] != nil)
        await rig.listener.stop(reason: "synthetic completion")
    }

    @Test func finalHeldSelectionAuthority() async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let held = try await rig.hold()
        await rig.adapter.handoff.arm()
        let delivery = Task { await rig.listener.sendHeld(held, from: rig.session.connectionID) }
        await rig.adapter.handoff.wait()
        _ = await rig.session.receive(sessionFrame(payload: .control(.select(targetID: "final:other"))))
        _ = await rig.session.receive(sessionFrame(payload: .control(.select(targetID: FinalDeliveryRig.target))))
        await rig.adapter.handoff.resume()
        #expect(await delivery.value == .refused(.selectionChanged))
        await rig.expectEmpty()
        #expect(await rig.host.heldRequests.entries[held] != nil)
        await rig.listener.stop(reason: "synthetic completion")
    }

    @Test func currentFinalAuthority() async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let held = try await rig.hold()
        #expect(await rig.listener.sendHeld(held, from: rig.session.connectionID) == .sent)
        #expect(await rig.adapter.deliveries == ["synthetic input"])
        let owner = try #require(await rig.adapter.contexts.first?.id)
        #expect(await rig.session.replyRequests[owner]?.committed == true)
        #expect(await rig.host.heldRequests.entries[held] == nil)
        await rig.listener.stop(reason: "synthetic completion")
    }
}
