import Testing
@testable import HailDaemonKit

/// The host's policy state (#41 items 1, 4): per-line recording and re-evaluation, allow/deny/tier saved
/// before they apply, and what an unusable or unwritable store refuses.
@Suite struct HostPolicyTests {
    let id = "tmux:a"
    let binding = "$1@1/%1:9"

    struct Fixture {
        var adapter: FakeAdapter
        var store: InMemoryPolicyStore
        var host: HailHost
    }

    func fixture(
        policy: Policy = Policy(), tier: Tier? = .confirm, sanitizing: SanitizePolicy = SanitizePolicy(),
        window: Duration = HailHost.confirmationWindow
    ) async throws -> Fixture {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: binding)])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = policy
        if let tier { try policy.allow(id, binding: binding, tier: tier) }
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, sanitizing: sanitizing, store: store, confirmationWindow: window)
        return Fixture(adapter: adapter, store: store, host: host)
    }

    func readBack(_ outcome: SendOutcome) throws -> ReadBack {
        guard case .needsConfirmation(let readBack) = outcome else {
            throw HostError.partial(delivered: [], reason: "expected a read-back, got \(outcome)")
        }
        return readBack
    }

    @Test func everyLineMustFitBeforeARequestStartsAndDeliveredLinesAreRecorded() async throws {
        let fx = try await fixture(
            policy: Policy(deliveriesPerMinute: 2), tier: .open, sanitizing: SanitizePolicy(newlines: .split)
        )
        await #expect(throws: HostError.denied(.rateLimited(retryAfter: .seconds(60)))) {
            try await fx.host.send("one\ntwo\nthree", to: id)
        }
        #expect(await fx.adapter.deliveries.isEmpty)
        #expect(try await fx.host.send("one\ntwo", to: id) == .delivered(["one", "two"]))
        #expect(await fx.adapter.deliveries.map(\.text) == ["one", "two"])
        // The wait is sixty seconds less the microseconds since the record, so match the case, not the value.
        var fourth: (any Error)?
        do { try await fx.host.send("four", to: id) } catch { fourth = error }
        guard case .denied(.rateLimited(let wait))? = fourth as? HostError else {
            Issue.record("expected a rate-limit denial, got \(String(describing: fourth))")
            return
        }
        #expect(wait > .seconds(59) && wait <= .seconds(60))
        #expect(await fx.adapter.deliveries.count == 2)
    }

    @Test func aDenyThatLandsWhileTheAdapterIsBusyStopsTheNextLine() async throws {
        let adapter = GatedFakeAdapter(AdapterTarget(name: "a", binding: binding))
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow(id, binding: binding, tier: .open)
        let host = try HailHost(
            registry: registry, sanitizing: SanitizePolicy(newlines: .split), store: InMemoryPolicyStore(policy)
        )
        async let arrival: Void = adapter.nextArrival()
        let sending = Task { try await host.send("one\ntwo\nthree", to: id) }
        await arrival
        // Line one is inside the adapter; the host actor is free, so the deny commits before line two.
        #expect(try await host.deny(id))
        await adapter.release()
        await #expect(throws: HostError.partial(delivered: ["one"], reason: "\(Denial.notAllowed(id))")) {
            try await sending.value
        }
        #expect(await adapter.deliveries == ["one"])
    }

    @Test func concurrentSendsCannotAllPassAdmissionOnTheSameHistory() async throws {
        let adapter = GatedFakeAdapter(AdapterTarget(name: "a", binding: binding))
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(deliveriesPerMinute: 1)
        try policy.allow(id, binding: binding, tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        async let arrival: Void = adapter.nextArrival()
        let first = Task { try await host.send("one", to: id) }
        await arrival
        // The first send is parked inside the adapter with its slot already spent.
        var second: (any Error)?
        do { try await host.send("two", to: id) } catch { second = error }
        guard case .denied(.rateLimited)? = second as? HostError else {
            Issue.record("expected the second send to be rate limited, got \(String(describing: second))")
            return
        }
        await adapter.release()
        #expect(try await first.value == .delivered(["one"]))
        #expect(await adapter.deliveries == ["one"])
    }

    @Test func allowPinsTheListedBindingAndPersistsBeforeItApplies() async throws {
        let fx = try await fixture(tier: nil)
        let allowed = try await fx.host.allow(id, tier: .open, capture: true)
        #expect(allowed == TargetPolicy(tier: .open, capture: true, binding: binding))
        #expect(fx.store.saved.last?.targets[id] == allowed)
        #expect(try await fx.host.send("echo hi", to: id) == .delivered(["echo hi"]))

        #expect(try await fx.host.setTier(.locked, for: id))
        #expect(fx.store.saved.last?.targets[id]?.tier == .locked)
        await #expect(throws: HostError.denied(.locked(id))) { try await fx.host.send("echo hi", to: id) }

        #expect(try await fx.host.deny(id))
        #expect(fx.store.saved.last?.targets.isEmpty == true)
        #expect(try await fx.host.deny(id) == false)
        #expect(try await fx.host.setTier(.open, for: id) == false)
        #expect(fx.store.saved.count == 3, "no-op changes are not saved")
    }

    @Test func aChangeAppliesToWhatIsStoredNowNotToThisProcessSnapshot() async throws {
        let fx = try await fixture(tier: .open)
        var elsewhere = Policy()
        try elsewhere.allow("tmux:other", binding: "$9@9/%9:9", tier: .locked)
        fx.store.overwrite(elsewhere)  // another haild denied "a" and allowed "other" meanwhile
        #expect(try await fx.host.setTier(.confirm, for: id) == false, "a is no longer allowed where it counts")
        #expect(fx.store.stored == elsewhere)
        _ = try await fx.host.allow(id, tier: .open)
        #expect(fx.store.stored.targets.keys.sorted() == [id, "tmux:other"], "the other change survives")
        #expect(fx.store.stored.targets["tmux:other"]?.tier == .locked)
        #expect(await fx.host.currentPolicy == fx.store.stored, "the host adopted what the store holds")
    }

    @Test func allowNeedsAListedBoundTarget() async throws {
        let fx = try await fixture(tier: nil)
        await #expect(throws: HostError.unknownTarget("tmux:b")) { try await fx.host.allow("tmux:b") }
        await fx.adapter.setTargets([AdapterTarget(name: "a")])
        await #expect(throws: HostError.denied(.unbound(id))) { try await fx.host.allow(id) }
        #expect(fx.store.saved.isEmpty)
    }

    @Test func reAllowingAfterAReboundPinsTheNewBinding() async throws {
        let fx = try await fixture(tier: .open)
        await fx.adapter.setTargets([AdapterTarget(name: "a", binding: "$2@2/%2:10")])
        await #expect(throws: HostError.denied(.rebound(id))) { try await fx.host.send("echo hi", to: id) }
        #expect(try await fx.host.allow(id, tier: .open).binding == "$2@2/%2:10")
        #expect(try await fx.host.send("echo hi", to: id) == .delivered(["echo hi"]))
    }

    @Test func anUnusablePolicyRefusesEverySendAndEveryChange() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: binding)])
        let registry = Registry()
        try await registry.register(adapter)
        let store = InMemoryPolicyStore(loadError: PolicyFileError.malformed("policy.json: garbage"))
        let host = try HailHost(registry: registry, store: store)

        #expect(await host.policyFailure == "malformed(\"policy.json: garbage\")")
        let expected = HostError.policyUnavailable("malformed(\"policy.json: garbage\")")
        await #expect(throws: expected) { try await host.send("echo hi", to: id) }
        await #expect(throws: expected) { try await host.allow(id) }
        await #expect(throws: expected) { try await host.deny(id) }
        #expect(store.saved.isEmpty)
        #expect(try await host.targets().count == 1, "listing still works; only delivery and changes are refused")
    }

    @Test func aFailedSaveLeavesThePolicyUnchanged() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: binding)])
        let registry = Registry()
        try await registry.register(adapter)
        let store = InMemoryPolicyStore(saveError: PolicyFileError.unwritable("disk full"))
        let host = try HailHost(registry: registry, store: store)

        await #expect(throws: PolicyFileError.unwritable("disk full")) { try await host.allow(id, tier: .open) }
        #expect(await host.currentPolicy.targets.isEmpty)
        await #expect(throws: HostError.denied(.notAllowed(id))) { try await host.send("echo hi", to: id) }
    }
}
