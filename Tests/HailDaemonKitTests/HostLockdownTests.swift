import Testing
@testable import HailDaemonKit

@Suite struct HostLockdownTests {
    let id = "tmux:a"
    let target = AdapterTarget(name: "a", binding: "b1")

    func host(_ adapter: GatedFakeAdapter, tier: Tier = .open) async throws -> HailHost {
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow(id, binding: "b1", tier: tier)
        return try HailHost(
            registry: registry, sanitizing: SanitizePolicy(newlines: .split),
            store: InMemoryPolicyStore(policy)
        )
    }

    func readBack(_ outcome: SendOutcome) throws -> ReadBack {
        guard case .needsConfirmation(let readBack) = outcome else {
            throw HostError.partial(delivered: [], reason: "expected a read-back")
        }
        return readBack
    }

    @Test func lockdownRefusesDelivery() async throws {
        let adapter = GatedFakeAdapter(target)
        let host = try await host(adapter)

        _ = await host.engageLockdown(reason: "manual panic")
        await #expect(throws: HostError.denied(.lockdown)) { try await host.send("one", to: id) }
        #expect(await adapter.deliveries.isEmpty)
        #expect(await host.currentLockdown.isOn)
    }

    @Test func lockdownWinsBeforeEverySendPreflight() async throws {
        let adapter = GatedFakeAdapter(target)
        let active = try await host(adapter)
        _ = await active.engageLockdown(reason: "manual panic")

        await #expect(throws: HostError.denied(.lockdown)) { try await active.send("", to: id) }
        await #expect(throws: HostError.denied(.lockdown)) { try await active.send("one", to: "tmux:missing") }

        let registry = Registry()
        let broken = try HailHost(
            registry: registry,
            store: InMemoryPolicyStore(loadError: PolicyFileError.malformed("policy.json: garbage"))
        )
        _ = await broken.engageLockdown(reason: "policy unavailable")
        await #expect(throws: HostError.denied(.lockdown)) { try await broken.send("one", to: id) }
    }

    @Test func lockdownDuringDeliveryStopsTheNextLine() async throws {
        let adapter = GatedFakeAdapter(target)
        let host = try await host(adapter)
        let delivery = Task { try await host.send("one\ntwo", to: id) }

        await adapter.nextArrival()
        _ = await host.engageLockdown(reason: "automatic trigger")
        await adapter.release()

        await #expect(throws: HostError.partial(delivered: ["one"], reason: "the host is in lockdown")) {
            try await delivery.value
        }
        #expect(await adapter.deliveries == ["one"])
    }

    @Test func lockdownDuringConfirmedDeliveryStopsAfterTheInFlightLine() async throws {
        let adapter = GatedFakeAdapter(target)
        let host = try await host(adapter, tier: .confirm)
        let readBack = try readBack(try await host.send("one\ntwo", to: id))
        let delivery = Task { try await host.send("one\ntwo", to: id, confirmedHash: readBack.hash) }

        await adapter.nextArrival()
        _ = await host.engageLockdown(reason: "manual panic")
        await adapter.release()

        await #expect(throws: HostError.partial(delivered: ["one"], reason: "the host is in lockdown")) {
            try await delivery.value
        }
        #expect(await adapter.deliveries == ["one"])
    }
}
