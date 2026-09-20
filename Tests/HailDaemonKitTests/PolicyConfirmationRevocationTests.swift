import Testing
@testable import HailDaemonKit

/// A waiting read-back cannot survive a revoke or other target-policy mutation (#87 items 6 and 7).
@Suite struct PolicyConfirmationRevocationTests {
    let id = "tmux:a"
    let binding = "$1@1/%1:9"

    struct Fixture {
        var adapter: FakeAdapter
        var store: InMemoryPolicyStore
        var host: HailHost
    }

    func fixture() async throws -> Fixture {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: binding)])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow(id, binding: binding)
        let store = InMemoryPolicyStore(policy)
        return try Fixture(adapter: adapter, store: store, host: HailHost(registry: registry, store: store))
    }

    func readBack(_ outcome: SendOutcome) throws -> ReadBack {
        guard case .needsConfirmation(let readBack) = outcome else {
            throw HostError.partial(delivered: [], reason: "expected a read-back, got \(outcome)")
        }
        return readBack
    }

    @Test func anExternalDenyIsReloadedBeforeAPendingConfirmation() async throws {
        let fx = try await fixture()
        let first = try readBack(try await fx.host.send("echo hi", to: id))
        fx.store.overwrite(Policy())

        await #expect(throws: HostError.denied(.notAllowed(id))) {
            try await fx.host.send("echo hi", to: id, confirmedHash: first.hash)
        }
        #expect(await fx.host.currentPolicy.targets.isEmpty)
        #expect(await fx.adapter.deliveries.isEmpty)
    }

    @Test func anExternalGuardChangeRequiresAFreshReadBack() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: binding)])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(guardPatterns: [GuardPattern(name: "old guard", regex: "echo hi")])
        try policy.allow(id, binding: binding, tier: .open)
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, store: store)
        let first = try readBack(try await host.send("echo hi", to: id))

        policy.guardPatterns = [GuardPattern(name: "new guard", regex: "echo hi")]
        store.overwrite(policy)
        let second = try readBack(try await host.send("echo hi", to: id, confirmedHash: first.hash))

        #expect(second.reason == "guarded: new guard")
        #expect(second.guardHits == ["new guard"])
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func aRepairedPolicyRecoversAfterATransientRefreshFailure() async throws {
        let fx = try await fixture()
        let first = try readBack(try await fx.host.send("echo hi", to: id))
        fx.store.setLoadError(PolicyFileError.malformed("transient read"))
        await #expect(throws: HostError.policyUnavailable("malformed(\"transient read\")")) {
            try await fx.host.send("echo hi", to: id, confirmedHash: first.hash)
        }

        fx.store.setLoadError(nil)
        _ = try readBack(try await fx.host.send("echo hi", to: id, confirmedHash: first.hash))
        #expect(await fx.host.policyFailure == nil)
        #expect(await fx.adapter.deliveries.isEmpty, "the failed refresh revoked the old confirmation")
    }

    @Test func aLocalCommitThatAdoptsExternalChangesDropsEveryConfirmation() async throws {
        let otherID = "tmux:b"
        let otherBinding = "$1@1/%2:10"
        let adapter = FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "a", binding: binding), AdapterTarget(name: "b", binding: otherBinding)
        ])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(guardPatterns: [GuardPattern(name: "old guard", regex: "echo hi")])
        try policy.allow(otherID, binding: otherBinding, tier: .open)
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, store: store)
        let first = try readBack(try await host.send("echo hi", to: otherID))

        policy.guardPatterns = [GuardPattern(name: "new guard", regex: "echo hi")]
        store.overwrite(policy)
        _ = try await host.allow(id, tier: .open)
        let second = try readBack(try await host.send("echo hi", to: otherID, confirmedHash: first.hash))

        #expect(second.reason == "guarded: new guard")
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func anExternalDenyDuringListingPrecedesConfirmationConsumption() async throws {
        let adapter = GatedListingFakeAdapter(AdapterTarget(name: "a", binding: binding))
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow(id, binding: binding)
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, store: store)
        let first = try readBack(try await host.send("echo hi", to: id))

        await adapter.gateNextListing()
        async let arrival: Void = adapter.nextListingArrival()
        let confirmed = Task { try await host.send("echo hi", to: id, confirmedHash: first.hash) }
        await arrival
        store.overwrite(Policy())
        await adapter.releaseListing()

        await #expect(throws: HostError.denied(.notAllowed(id))) { try await confirmed.value }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func policyChangesDropOldConfirmationsForThatTarget() async throws {
        let fx = try await fixture()
        let beforeDeny = try readBack(try await fx.host.send("echo hi", to: id))
        #expect(try await fx.host.deny(id))
        _ = try await fx.host.allow(id)
        _ = try readBack(try await fx.host.send("echo hi", to: id, confirmedHash: beforeDeny.hash))
        #expect(await fx.adapter.deliveries.isEmpty)

        let beforeTier = try readBack(try await fx.host.send("echo two", to: id))
        #expect(try await fx.host.setTier(.open, for: id))
        #expect(try await fx.host.setTier(.confirm, for: id))
        _ = try readBack(try await fx.host.send("echo two", to: id, confirmedHash: beforeTier.hash))
        #expect(await fx.adapter.deliveries.isEmpty)
    }
}
