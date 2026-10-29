import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

private final class SelectionPreflightStore: PolicyStore {
    private let backing: InMemoryPolicyStore
    private let nextLoad = Mutex<SelectionPreflightLoadGate?>(nil)
    let summary = "synthetic selection preflight policy"

    init(_ policy: Policy) { backing = InMemoryPolicyStore(policy) }

    func gateNextLoad(_ gate: SelectionPreflightLoadGate) { nextLoad.withLock { $0 = gate } }

    func load() throws -> Policy {
        let gate: SelectionPreflightLoadGate? = nextLoad.withLock { state in
            defer { state = nil }
            return state
        }
        gate?.suspend()
        return try backing.load()
    }

    func update(_ change: (inout Policy) throws -> Void) throws -> PolicyUpdate {
        try backing.update(change)
    }
}

private struct SelectionPreflightRig {
    let adapter: SelectionPreflightAdapter
    let store: SelectionPreflightStore
    let host: HailHost
    let session: HostSession

    static func make(listing: SelectionPreflightListing) async throws -> Self {
        let adapter = SelectionPreflightAdapter(listing: listing)
        let registry = Registry()
        try await registry.register(adapter)
        let other = FakeAdapter(kind: "other", targets: [AdapterTarget(name: "b", binding: "binding-b")])
        try await registry.register(other)
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        try policy.allow("other:b", binding: "binding-b", tier: .open)
        let store = SelectionPreflightStore(policy)
        let host = try HailHost(registry: registry, store: store)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        let selected: HostSessionResult = await session.receive(
            sessionFrame(payload: .control(.select(targetID: "tmux:a")))
        )
        try #require(selected.frames.isEmpty)
        return Self(adapter: adapter, store: store, host: host, session: session)
    }
}

extension HostSession {
    /// Apply the phone's accepted selection transitions without policy I/O: the load gate holds the host actor.
    fileprivate func reselectDuringPreflight() {
        for target in ["other:b", "tmux:a"] {
            selectionGeneration = UUID()
            replyRequests.removeAll()
            evictedForHandoff.removeAll()
            selectedTarget = target
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct LocalDispatchPreflightSelectionTests {
    @Test func reselectionDuringSendPreflightRevokesDispatch() async throws {
        let listing = SelectionPreflightListing()
        let loading = SelectionPreflightLoadGate()
        defer {
            loading.fire()
            listing.close()
        }
        let rig = try await selectionPreflightStep("fixture setup") {
            try await SelectionPreflightRig.make(listing: listing)
        }
        let dispatchExecutor = RecipientPublicationExecutor()
        let generation = try await selectionPreflightStep("initial generation") {
            await rig.session.selectionGeneration
        }
        listing.arm()
        let request = dispatchRequest(connection: UUID(), target: "tmux:a", binding: "binding-a")
        let dispatch = Task(executorPreference: dispatchExecutor) {
            defer { listing.dispatchFinished() }
            return try await rig.session.dispatch(request)
        }
        defer { dispatch.cancel() }
        try await listing.arrival.wait("listing arrival")
        // Authorization has captured an unchanged policy grant. Hold the host in a successful reload so
        // deliver's cross-actor preflight must suspend, without retiring that grant.
        rig.store.gateNextLoad(loading)
        let refreshing = Task(executorPreference: loading.executor) { await rig.host.refreshedPolicy() }
        defer { refreshing.cancel() }
        try await selectionPreflightStep("policy reload entry") { try await loading.waitUntilSuspended() }
        listing.release()
        // Drain the dispatch executor after its listing continuation has suspended at host preflight.
        let checkpoint = Task(executorPreference: dispatchExecutor) { await rig.session.selectionGeneration }
        defer { checkpoint.cancel() }
        let captured = try await selectionPreflightStep("dispatch checkpoint") { await checkpoint.value }
        try #require(captured == generation)
        try await selectionPreflightStep("reselection") { await Self.reselect(rig, generation: generation) }
        loading.fire()
        let refreshed = try await selectionPreflightStep("policy reload completion") { await refreshing.value }
        try #require(refreshed != nil)
        let result = try await selectionPreflightStep("dispatch completion") { await dispatch.result }
        #expect(throws: LocalDispatchRefusal.selectionChanged) { try result.get() }
        let deliveries = try await selectionPreflightStep("deliveries") { await rig.adapter.deliveries }
        #expect(deliveries.isEmpty)
    }

    private static func reselect(_ rig: SelectionPreflightRig, generation: UUID) async {
        await rig.session.reselectDuringPreflight()
        let target: String? = await rig.session.selectedTarget
        let replacement: UUID = await rig.session.selectionGeneration
        #expect(target == "tmux:a")
        #expect(replacement != generation)
    }
}
