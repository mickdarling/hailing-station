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

    @Test func waitingDiscardAfterRefusalPrecedesRetryWithoutOrphaningIt() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        let store = rig.host.heldRequests
        let refusal = HeldDecisionGate(result: .refused(.capacity))
        var arrivals = refusal.arrivals.stream.makeAsyncIterator()
        let first = await store.queueSend(entry.id, from: entry.connection) { _ in await refusal.run() }
        _ = await arrivals.next()
        let discard = await store.queueDiscard(entry.id, from: entry.connection)
        await refusal.release()
        #expect(await first.value == .refused(.capacity))
        let retry = HeldDecisionGate(result: .sent)
        let retried = await store.queueSend(entry.id, from: entry.connection) { _ in await retry.run() }
        #expect(await discard.value == .discarded)
        #expect(await retried.value == .discarded)
        #expect(await retry.attempts == 0)
        #expect(await store.status(entry.id, from: entry.connection) == .discarded)
        #expect(await store.entries[entry.id] == nil)
    }

    @Test(arguments: [false, true])
    func discardWaitsForCurrentRetryAndReplaysItsState(sent: Bool) async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        let store = rig.host.heldRequests
        #expect(await store.send(entry.id, from: entry.connection) { _ in .refused(.capacity) }
            == .refused(.capacity))
        let retry = HeldDecisionGate(result: sent ? .sent : .refused(.capacity))
        var arrivals = retry.arrivals.stream.makeAsyncIterator()
        let retried = await store.queueSend(entry.id, from: entry.connection) { _ in await retry.run() }
        _ = await arrivals.next()
        let discard = await store.queueDiscard(entry.id, from: entry.connection)
        let later = await store.queueSend(entry.id, from: entry.connection) { _ in
            Issue.record("A queued decision must not start another handoff after Discard")
            return .sent
        }
        await retry.release()
        #expect(await retried.value == (sent ? .sent : .refused(.capacity)))
        #expect(await discard.value == (sent ? .sent : .discarded))
        #expect(await later.value == (sent ? .sent : .discarded))
        #expect(await retry.attempts == 1)
        #expect(await store.status(entry.id, from: entry.connection) == (sent ? .sent : .discarded))
        #expect(await store.entries[entry.id] == nil)
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

private actor HeldDecisionGate {
    let arrivals = AsyncStream<Void>.makeStream()
    private let result: HeldSendResult
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var attempts = 0
    init(result: HeldSendResult) { self.result = result }
    func run() async -> HeldSendResult {
        attempts += 1
        arrivals.continuation.yield(())
        await withCheckedContinuation { continuation = $0 }
        return result
    }
    func release() { continuation?.resume(); continuation = nil }
}
