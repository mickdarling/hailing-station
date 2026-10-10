import HailProtocol
import Testing
@testable import HailDaemonKit

/// A device's target list reads the stored policy, not the daemon's startup snapshot (#386): a CLI
/// `targets allow`, `deny` or a re-pin after a rebound lands on the next list, with no restart.
@Suite struct TargetListPolicyReloadTests {
    let id = "tmux:a"

    func connected(_ store: InMemoryPolicyStore) async throws -> (HailHost, HostSession) {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "now")])
        let registry = Registry()
        try await registry.register(adapter)
        let host = try HailHost(registry: registry, store: store)
        let session = HostSession(host: host)
        _ = await session.receive(helloFrame())
        return (host, session)
    }

    func list(_ session: HostSession) async throws -> [String] {
        let result = await session.receive(sessionFrame(payload: .control(.listTargets)))
        guard case .targets(let targets) = try onlyControl(result) else { throw TestSupportError.expectedOneControl }
        return targets.map(\.id)
    }

    func allowing(at binding: String) throws -> Policy {
        var policy = Policy()
        try policy.allow(id, binding: binding, tier: .open)
        return policy
    }

    @Test func anAllowStoredAfterStartupIsListedWithoutARestart() async throws {
        let store = InMemoryPolicyStore()
        let (_, session) = try await connected(store)
        #expect(try await list(session).isEmpty)

        store.overwrite(try allowing(at: "now"))
        #expect(try await list(session) == [id])

        store.overwrite(Policy())
        #expect(try await list(session).isEmpty, "a deny by another process lands too")
    }

    @Test func aRebindRePinnedByAnotherProcessIsListedAgain() async throws {
        let store = InMemoryPolicyStore(try allowing(at: "before"))
        let (_, session) = try await connected(store)
        #expect(try await list(session).isEmpty, "rebound: allowed at the old binding")

        store.overwrite(try allowing(at: "now"))
        #expect(try await list(session) == [id])
    }

    @Test func aStoredPolicyThatBecomesUnusableListsNothing() async throws {
        let store = InMemoryPolicyStore(try allowing(at: "now"))
        let (host, session) = try await connected(store)
        #expect(try await list(session) == [id])

        store.setLoadError(PolicyFileError.malformed("policy.json: garbage"))
        #expect(try await list(session).isEmpty)
        #expect(await host.policyFailure != nil, "and the host records the failure")
    }
}
