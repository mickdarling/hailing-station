import Testing
@testable import HailDaemonKit

/// The host side of #41: deny by default, the read-back on `confirm`, the confirmation bound to one
/// utterance, per-line recording and re-evaluation, and allow/deny/tier persisted before they apply.
@Suite struct ConfirmationFlowTests {
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

    @Test func aFreshTargetIsDeniedWithASpokenReason() async throws {
        let fx = try await fixture(tier: nil)
        await #expect(throws: HostError.denied(.notAllowed(id))) { try await fx.host.send("echo hi", to: id) }
        #expect(HostError.denied(.notAllowed(id)) == .denied(.notAllowed(id)))
        #expect("\(Denial.notAllowed(id))" == "target tmux:a is not allowed")
        #expect(await fx.adapter.deliveries.isEmpty)
    }

    @Test func confirmTierReadsBackThenDeliversThatUtteranceOnce() async throws {
        let fx = try await fixture()
        let first = try readBack(try await fx.host.send("echo hi", to: id))
        #expect(first.lines == ["echo hi"])
        #expect(first.reason == "confirm tier")
        #expect(await fx.adapter.deliveries.isEmpty, "nothing goes out before the read-back")

        let outcome = try await fx.host.send("echo hi", to: id, confirmedHash: first.hash)
        #expect(outcome == .delivered(["echo hi"]))
        #expect(await fx.adapter.deliveries.map(\.text) == ["echo hi"])

        let again = try readBack(try await fx.host.send("echo hi", to: id, confirmedHash: first.hash))
        #expect(again.hash == first.hash, "single use: the same words need a new read-back")
        #expect(await fx.adapter.deliveries.count == 1)
    }

    @Test func aConfirmationBindsToTheExactLinesTargetBindingAndDevice() async throws {
        let fx = try await fixture()
        let first = try readBack(try await fx.host.send("rm -rf x", to: id))

        let otherWords = try readBack(try await fx.host.send("rm -rf y", to: id, confirmedHash: first.hash))
        #expect(otherWords.lines == ["rm -rf y"])
        let otherDevice = try readBack(
            try await fx.host.send("rm -rf x", to: id, from: "ipad", confirmedHash: first.hash)
        )
        #expect(otherDevice.lines == ["rm -rf x"])
        let stillGood = try await fx.host.send("rm -rf x", to: id, confirmedHash: first.hash)
        #expect(stillGood == .delivered(["rm -rf x"]), "presenting it with the wrong words did not burn it")
        await fx.adapter.setTargets([AdapterTarget(name: "a", binding: "$1@1/%1:9")])
        _ = try readBack(try await fx.host.send("rm -rf x", to: id))

        await fx.adapter.setTargets([AdapterTarget(name: "a", binding: "$2@2/%2:10")])
        await #expect(throws: HostError.denied(.rebound(id))) {
            try await fx.host.send("rm -rf x", to: id, confirmedHash: first.hash)
        }
        #expect(await fx.adapter.deliveries.map(\.text) == ["rm -rf x"])
    }

    @Test func cancelDropsAReadBackBeforeTheWindowEnds() async throws {
        let fx = try await fixture()
        let first = try readBack(try await fx.host.send("echo hi", to: id))
        #expect(await fx.host.cancel(first.hash))
        #expect(await fx.host.cancel(first.hash) == false)
        let again = try readBack(try await fx.host.send("echo hi", to: id, confirmedHash: first.hash))
        #expect(again.hash == first.hash)
        #expect(await fx.adapter.deliveries.isEmpty)
    }

    @Test func outstandingReadBacksAreBoundedOldestFirst() async throws {
        let fx = try await fixture()
        let first = try readBack(try await fx.host.send("echo 0", to: id))
        for index in 1...HailHost.pendingLimit { _ = try readBack(try await fx.host.send("echo \(index)", to: id)) }
        let evicted = try readBack(try await fx.host.send("echo 0", to: id, confirmedHash: first.hash))
        #expect(evicted.hash == first.hash, "the oldest read-back was dropped to make room")
        let last = try readBack(try await fx.host.send("echo \(HailHost.pendingLimit)", to: id))
        #expect(try await fx.host.send("echo \(HailHost.pendingLimit)", to: id, confirmedHash: last.hash)
            == .delivered(["echo \(HailHost.pendingLimit)"]))
    }

    @Test func aHashTheHostDidNotIssueConfirmsNothing() async throws {
        let fx = try await fixture()
        let forged = DeliveryRequest(target: id, binding: binding, lines: ["echo hi"], device: "keyboard")
        let outcome = try readBack(try await fx.host.send("echo hi", to: id, confirmedHash: forged.confirmationHash))
        #expect(outcome.hash == forged.confirmationHash, "the hash is right, the issue is missing")
        #expect(await fx.adapter.deliveries.isEmpty)
    }

    @Test func anExpiredConfirmationNeedsAFreshReadBack() async throws {
        let fx = try await fixture(window: .zero)
        let first = try readBack(try await fx.host.send("echo hi", to: id))
        let outcome = try readBack(try await fx.host.send("echo hi", to: id, confirmedHash: first.hash))
        #expect(outcome.hash == first.hash)
        #expect(await fx.adapter.deliveries.isEmpty)
    }

    @Test func anOpenTargetDeliversAndAGuardedLineIsReadBack() async throws {
        let fx = try await fixture(tier: .open)
        #expect(try await fx.host.send("echo hi", to: id) == .delivered(["echo hi"]))

        let first = try readBack(try await fx.host.send("sudo rm -rf /", to: id))
        #expect(first.reason == "guarded: rm -rf, sudo")
        #expect(first.guardHits == ["rm -rf", "sudo"])
        #expect(try await fx.host.send("sudo rm -rf /", to: id, confirmedHash: first.hash)
            == .delivered(["sudo rm -rf /"]))
        #expect(await fx.adapter.deliveries.map(\.text) == ["echo hi", "sudo rm -rf /"])
    }

    @Test func anIssuedConfirmationNeverOverridesADenial() async throws {
        let fx = try await fixture()
        let first = try readBack(try await fx.host.send("echo hi", to: id))
        #expect(try await fx.host.setTier(.locked, for: id))
        await #expect(throws: HostError.denied(.locked(id))) {
            try await fx.host.send("echo hi", to: id, confirmedHash: first.hash)
        }
        #expect(try await fx.host.deny(id))
        await #expect(throws: HostError.denied(.notAllowed(id))) {
            try await fx.host.send("echo hi", to: id, confirmedHash: first.hash)
        }
        #expect(await fx.adapter.deliveries.isEmpty)

        let limited = try await fixture(policy: Policy(deliveriesPerMinute: 1), tier: .open)
        let guarded = try readBack(try await limited.host.send("sudo ls", to: id))
        #expect(guarded.guardHits == ["sudo"])
        #expect(try await limited.host.send("echo one", to: id) == .delivered(["echo one"]), "spends the slot")
        var refused: (any Error)?
        do { try await limited.host.send("sudo ls", to: id, confirmedHash: guarded.hash) } catch { refused = error }
        guard case .denied(.rateLimited)? = refused as? HostError else {
            Issue.record("expected a rate-limit denial, got \(String(describing: refused))")
            return
        }
        #expect(await limited.adapter.deliveries.map(\.text) == ["echo one"])
    }
}
