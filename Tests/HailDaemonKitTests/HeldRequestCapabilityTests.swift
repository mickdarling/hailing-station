import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct HeldRequestCapabilityTests {
    @Test(arguments: [Tier.open, .confirm])
    func unnegotiatedConfirmationCancelsReadBack(tier: Tier) async throws {
        let rig = try await HeldTestRig.make(tier: tier, capabilities: [])
        let text = tier == .open ? "HELD_TOKEN" : "benign confirm-tier request"
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) { try await rig.dispatch(text) }
        #expect(await rig.host.heldRequests.entries.isEmpty)
        #expect(await rig.session.replyRequests.isEmpty)
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await rig.host.cancel(hash(text)) == false)
        let connection = await rig.session.connectionID
        var slots: [UUID] = []
        for _ in 0..<HeldRequestStore.perConnection {
            slots.append(try #require(await rig.host.heldRequests.reserve(connection: connection)))
        }
        for slot in slots { await rig.host.heldRequests.release(slot) }
    }

    @Test func unnegotiatedTimeoutCancelsReadBackAndNextRequestDelivers() async throws {
        let rig = try await HeldTestRig.make(capabilities: [])
        let text = "benign timed-out request"
        let budget = GuardBudgetClock(now: { .now }, cpuNow: { nil })
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) {
            try await GuardBudgetClock.$current.withValue(budget) { try await rig.dispatch(text) }
        }
        #expect(await rig.host.cancel(hash(text)) == false)
        #expect(await rig.host.heldRequests.entries.isEmpty)
        guard case .delivered = try await rig.dispatch("benign next request") else {
            Issue.record("timeout refusal prevented the next request")
            return
        }
        #expect(await rig.adapter.contexts.count == 1)
    }

    @Test func manyUnnegotiatedGuardHitsSpendNeitherConnectionNorHostAdmission() async throws {
        let rig = try await HeldTestRig.make(capabilities: [])
        for index in 0..<9 {
            let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer())
            _ = await session.receive(helloFrame())
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
            let peer = HeldTestRig(host: rig.host, adapter: rig.adapter, session: session,
                                   clock: rig.clock, privacy: rig.privacy, store: rig.store)
            for attempt in 0..<9 {
                let text = "HELD_TOKEN \(index) \(attempt)"
                await #expect(throws: LocalDispatchRefusal.confirmationRequired) { try await peer.dispatch(text) }
                #expect(await rig.host.cancel(hash(text)) == false)
            }
            guard case .delivered = try await peer.dispatch("benign next request") else {
                Issue.record("guard refusals exhausted admission")
                return
            }
        }
        #expect(await rig.host.heldRequests.entries.isEmpty)
        #expect(await rig.adapter.contexts.count == 9)
        let connection = await rig.session.connectionID
        var slots: [UUID] = []
        for index in 0..<HeldRequestStore.hostLimit {
            let owner = index < HeldRequestStore.perConnection ? connection : UUID()
            slots.append(try #require(await rig.host.heldRequests.reserve(connection: owner)))
        }
        for slot in slots { await rig.host.heldRequests.release(slot) }
    }

    @Test func fullStoreDoesNotAffectAnUnnegotiatedPeer() async throws {
        let rig = try await HeldTestRig.make(capabilities: [])
        let connection = await rig.session.connectionID
        for index in 0..<HeldRequestStore.hostLimit {
            let owner = index < HeldRequestStore.perConnection ? connection : UUID()
            _ = try #require(await rig.host.heldRequests.reserve(connection: owner))
        }
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) { try await rig.dispatch() }
        #expect(await rig.host.cancel(hash("HELD_TOKEN")) == false)
        guard case .delivered = try await rig.dispatch("benign with full store") else {
            Issue.record("unnegotiated peer consulted held capacity")
            return
        }
        #expect(await rig.host.heldRequests.entries.isEmpty)
    }

    @Test func unnegotiatedRateLimitKeepsTheExistingRefusal() async throws {
        let rig = try await HeldTestRig.make(limit: 1, capabilities: [])
        _ = try await rig.dispatch("first benign")
        await #expect(throws: LocalDispatchRefusal.capacityExceeded) { try await rig.dispatch("second benign") }
        #expect(await rig.host.cancel(hash("second benign")) == false)
        #expect(await rig.host.heldRequests.entries.isEmpty)
        rig.clock.advance(60_001)
        guard case .delivered = try await rig.dispatch("third benign") else {
            Issue.record("rate-limit refusal prevented a later request")
            return
        }
    }

    private func hash(_ text: String) -> String {
        DeliveryRequest(target: RecipientTestRig.target, binding: "reply-binding", lines: [text],
                        device: HostSession.dispatchDevice).confirmationHash
    }
}
