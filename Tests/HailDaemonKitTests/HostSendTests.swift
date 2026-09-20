import Testing
@testable import HailDaemonKit

@Suite struct HostSendTests {
    /// A host whose policy allows every target the adapter lists, at `tier`, pinned to its listed binding.
    func host(
        _ adapter: FakeAdapter, tier: Tier = .open, sanitizing: SanitizePolicy = SanitizePolicy()
    ) async throws -> HailHost {
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        for target in try await adapter.listTargets() {
            let id = Registry.id(kind: adapter.kind, name: target.name)
            try policy.allow(id, binding: target.binding ?? "", tier: tier)
        }
        return try HailHost(registry: registry, sanitizing: sanitizing, store: InMemoryPolicyStore(policy))
    }

    @Test func sendSanitisesThenDeliversWithTheListedBinding() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "claude-hail", binding: "$1@1/%1:9")])
        let host = try await host(adapter)

        let outcome = try await host.send("echo \u{1B}[31mhi\u{1B}[0m\u{00A0}there  ", to: "tmux:claude-hail")

        #expect(outcome == .delivered(["echo hi there"]))
        #expect(await adapter.deliveries.map(\.text) == ["echo hi there"])
        #expect(await adapter.deliveries.map(\.binding) == ["$1@1/%1:9"])
    }

    @Test func refusedTextNeverReachesAnAdapter() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b1")])
        let host = try await host(adapter)

        await #expect(throws: HostError.refused(.containsLineBreak)) {
            try await host.send("rm -rf x\necho y", to: "tmux:a")
        }
        await #expect(throws: HostError.refused(.hiddenCharacters("bidirectional control"))) {
            try await host.send("safe\u{202E}rm", to: "tmux:a")
        }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func unknownTargetIsRefusedBeforeDelivery() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b1")])
        let host = try await host(adapter)

        await #expect(throws: HostError.unknownTarget("tmux:b")) { try await host.send("x", to: "tmux:b") }
        await #expect(throws: HostError.unknownTarget("nope")) { try await host.send("x", to: "nope") }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func splitPolicyDeliversOneLineAtATime() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b1")])
        let host = try await host(adapter, sanitizing: SanitizePolicy(newlines: .split))

        let outcome = try await host.send("one\ntwo\n\nthree", to: "tmux:a")

        #expect(outcome == .delivered(["one", "two", "three"]))
        #expect(await adapter.deliveries.map(\.text) == ["one", "two", "three"])
    }

    @Test func aTargetWithoutABindingIsRefused() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a")])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:a", binding: "b1", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))

        await #expect(throws: HostError.denied(.unbound("tmux:a"))) { try await host.send("x", to: "tmux:a") }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func anUnlistableAdapterIsReportedNotMistakenForAnUnknownTarget() async throws {
        let adapter = FakeAdapter(kind: "tmux", listError: AdapterError.captureFailed("tmux: command not found"))
        let registry = Registry()
        try await registry.register(adapter)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore())
        let expected = HostError.adapterUnavailable(kind: "tmux", reason: "captureFailed(\"tmux: command not found\")")
        await #expect(throws: expected) { try await host.send("x", to: "tmux:a") }
    }

    @Test func partialDeliveryReportsWhatWentOut() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b1")], failAfter: 1)
        let host = try await host(adapter, sanitizing: SanitizePolicy(newlines: .split))

        await #expect(throws: HostError.partial(delivered: ["one"], reason: "rebound(\"a\")")) {
            try await host.send("one\ntwo\nthree", to: "tmux:a")
        }
        #expect(await adapter.deliveries.map(\.text) == ["one"])
    }

    @Test func adapterRefusalSurfacesUnchanged() async throws {
        let target = AdapterTarget(name: "a", binding: "b1")
        let adapter = FakeAdapter(kind: "tmux", targets: [target], deliverError: AdapterError.rebound("a"))
        let host = try await host(adapter)
        await #expect(throws: AdapterError.rebound("a")) { try await host.send("x", to: "tmux:a") }
    }
}
