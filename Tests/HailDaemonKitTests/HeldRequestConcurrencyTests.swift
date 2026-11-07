import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct HeldRequestConcurrencyTests {
    @Test func overlappingSendAndDiscardHaveOnlyOneHandoff() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        await rig.adapter.holdNextListing()
        var arrivals = rig.adapter.listingEvents.stream.makeAsyncIterator()
        async let first = rig.send(entry.id)
        _ = await arrivals.next()
        async let duplicate = rig.send(entry.id)
        async let conflicting = rig.discard(entry.id)
        await rig.adapter.releaseListing()
        #expect(await first == .sent)
        #expect(await duplicate == .sent)
        #expect(await conflicting == .sent)
        #expect(await rig.adapter.contexts.count == 1)
    }

    @Test func selectionChangeDuringFreshListingCannotDeliver() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        await rig.adapter.holdNextListing()
        var arrivals = rig.adapter.listingEvents.stream.makeAsyncIterator()
        async let send = rig.send(entry.id)
        _ = await arrivals.next()
        await rig.select("recipient:other")
        await rig.select(RecipientTestRig.target)
        await rig.adapter.releaseListing()
        #expect(await send == .refused(.selectionChanged))
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
    }

    @Test(arguments: HeldHandoffChange.allCases)
    func changesAfterEvaluationStillRefuseAtAdapterAuthority(_ change: HeldHandoffChange) async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        let gate = HeldHandoffGate()
        var arrivals = gate.arrivals.stream.makeAsyncIterator()
        async let result = HeldPeerScope.$current.withValue({ await gate.check() }, operation: {
            await rig.send(entry.id)
        })
        _ = await arrivals.next()
        switch change {
        case .policy:
            var policy = rig.store.stored
            policy.guardPatterns = [.init(name: "new guard", regex: "NEVER_MATCHES")]
            rig.store.overwrite(policy)
            _ = await rig.host.refreshedPolicy()
        case .lockdown: _ = await rig.host.engageLockdown(reason: "synthetic")
        case .privacy: rig.privacy.isOn = true
        case .expiry: rig.clock.advance(120_000)
        }
        await gate.release()
        let reason: HeldRequestRefusalReason = change == .policy ? .policyChanged
            : change == .expiry ? .denied : .lockdown
        #expect(await result == .refused(reason))
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await rig.host.heldRequests.status(entry.id, from: entry.connection) == .pending)
    }

    @Test func uncertainAdapterHandoffBlocksSubsequentSendUntilReconciliation() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        await rig.adapter.failHandoff()
        #expect(await rig.send(entry.id) == .refused(.denied))
        await rig.adapter.passHandoff()
        #expect(await rig.send(entry.id) == .refused(.denied))
        #expect(await rig.adapter.contexts.count == 1)
        #expect(await rig.host.heldRequests.status(entry.id, from: entry.connection) == .unresolved)
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
        #expect(await rig.discard(entry.id) == .discarded)
    }
}

private actor HeldHandoffGate {
    let arrivals = AsyncStream<Void>.makeStream()
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func check() async -> Bool {
        count += 1
        if count == 2 {
            arrivals.continuation.yield(())
            await withCheckedContinuation { continuation = $0 }
        }
        return true
    }
    func release() { continuation?.resume(); continuation = nil }
}

enum HeldHandoffChange: CaseIterable, Sendable { case policy, lockdown, privacy, expiry }
