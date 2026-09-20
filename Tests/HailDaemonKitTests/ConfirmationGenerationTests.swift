import Testing
@testable import HailDaemonKit

@Suite struct ConfirmationGenerationTests {
    @Test func aConsumedConfirmationDoesNotSurviveAPolicyChangeBetweenLines() async throws {
        let id = "tmux:a"
        let binding = "$1@1/%1:9"
        let adapter = GatedFakeAdapter(AdapterTarget(name: "a", binding: binding))
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow(id, binding: binding, tier: .open)
        let host = try HailHost(
            registry: registry, sanitizing: SanitizePolicy(newlines: .split), store: InMemoryPolicyStore(policy)
        )
        let text = "sudo echo one\ntwo"
        guard case .needsConfirmation(let readBack) = try await host.send(text, to: id) else {
            Issue.record("expected the guard to issue a read-back")
            return
        }
        async let arrival: Void = adapter.nextArrival()
        let sending = Task { try await host.send(text, to: id, confirmedHash: readBack.hash) }
        await arrival
        #expect(try await host.setTier(.confirm, for: id))
        await adapter.release()
        await #expect(throws: HostError.partial(delivered: ["sudo echo one"], reason: "confirm tier")) {
            try await sending.value
        }
        #expect(await adapter.deliveries == ["sudo echo one"])
    }
}
