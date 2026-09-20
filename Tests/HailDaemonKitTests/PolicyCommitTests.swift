import Testing
@testable import HailDaemonKit

/// The host adopts exactly what a policy transaction says readers now see (#87 items 3 and 4).
@Suite struct PolicyCommitTests {
    let id = "tmux:a"
    let binding = "$1@1/%1:9"

    func makeHost(store: InMemoryPolicyStore) async throws -> HailHost {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: binding)])
        let registry = Registry()
        try await registry.register(adapter)
        return try HailHost(registry: registry, store: store)
    }

    @Test func commitCompilesAndAdoptsThePolicyReturnedByTheStore() async throws {
        var original = Policy()
        try original.allow(id, binding: binding, tier: .confirm)
        var returned = original
        _ = returned.setTier(.locked, for: id)
        let store = InMemoryPolicyStore(original, returnedPolicy: returned)
        let host = try await makeHost(store: store)

        #expect(try await host.setTier(.open, for: id))
        #expect(await host.currentPolicy.targets[id]?.tier == .locked)
        await #expect(throws: HostError.denied(.locked(id))) { try await host.send("echo hi", to: id) }
    }

    @Test func aPostRenameDurabilityFailureIsReportedAfterTheHostAdoptsThePolicy() async throws {
        let failure = PolicyFileError.unwritable("config directory sync failed")
        let store = InMemoryPolicyStore(durabilityFailure: failure)
        let host = try await makeHost(store: store)

        await #expect(throws: failure) { try await host.allow(id, tier: .open) }
        #expect(await host.currentPolicy.targets[id]?.tier == .open)
        #expect(store.stored.targets[id]?.tier == .open)
        #expect(try await host.send("echo hi", to: id) == .delivered(["echo hi"]))
    }

    @Test func anInvalidPolicyReturnedAfterACommitFailsTheHostClosed() async throws {
        var original = Policy()
        try original.allow(id, binding: binding)
        let invalid = Policy(guardPatterns: [GuardPattern(name: "bad", regex: "[")])
        let host = try await makeHost(store: InMemoryPolicyStore(original, returnedPolicy: invalid))

        await #expect(throws: PolicyFormatError.invalidGuardPattern("bad")) {
            try await host.setTier(.open, for: id)
        }
        #expect(await host.policyFailure != nil)
        #expect(try await host.send("echo hi", to: id) == .delivered(["echo hi"]))
        #expect(await host.policyFailure == nil, "the next call reloads the valid policy the store committed")
    }
}
