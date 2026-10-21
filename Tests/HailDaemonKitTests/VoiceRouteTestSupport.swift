#if os(macOS)
import Foundation
import HailProtocol
@testable import HailDaemonKit

/// Routes `scratch`, `deck`, `voice` (not running) and `rogue` (running, never allowed), plus an allowed non-route
/// `other`, on a fake tmux adapter; and an `agent` route on a fake `codex-owned` adapter, the one kind that takes a paste.
struct VoiceRouteRig {
    static let scratch = "tmux:scratch", deck = "tmux:deck", other = "tmux:other", agent = "codex-owned:agent"
    let host: HailHost
    let adapter: FakeAdapter
    let agentAdapter: FakeAdapter
    let store: InMemoryPolicyStore
    let listener: WebSocketListener
    let clock = RecipientTestClock()

    static func make() async throws -> Self {
        let adapter = FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "scratch", binding: "s"), AdapterTarget(name: "deck", binding: "d"),
            AdapterTarget(name: "other", binding: "o"), AdapterTarget(name: "rogue", binding: "r")
        ], refusesFramedPastes: true) // its panes are not agents: a framed paste is refused in the adapter (#675)
        let agentAdapter = FakeAdapter(kind: "codex-owned", targets: [AdapterTarget(name: "agent", binding: "a")])
        let registry = Registry()
        try await registry.register(adapter)
        try await registry.register(agentAdapter)
        // One authored guard keeps unrelated default-guard wall budgets out of this suite.
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")],
                            deliveriesPerMinute: 1_000)
        for (target, binding) in [(scratch, "s"), (deck, "d"), (other, "o"), (agent, "a")] {
            try policy.allow(target, binding: binding, tier: .open)
        }
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, store: store)
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host, authorizer: PersonalTerminalAuthorizer(),
            hostName: "mac-test", singleTerminalReplyFallback: true, log: { _ in }
        )
        return Self(host: host, adapter: adapter, agentAdapter: agentAdapter, store: store, listener: listener)
    }

    static func routes() throws -> VoiceRoutes {
        try VoiceRoutes(defaultTarget: scratch, routes: [
            .init(target: scratch, name: "Hailing Scratch"), .init(target: deck, name: "Deck"),
            .init(target: "tmux:voice", name: "Voice Work"), .init(target: "tmux:rogue", name: "Rogue"),
            .init(target: agent, name: "Agent")
        ])
    }

    /// A negotiated session with the owner's routes, selecting `target`, recording into the listener's ledger.
    func session(selecting target: String = scratch, routes: VoiceRoutes? = nil) async throws -> HostSession {
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer().naming(routes),
                                  hostName: "mac-test", now: clock.now, requestClock: clock.instant)
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        return session
    }

    static func tap(_ text: String, to target: String = scratch) -> Frame {
        sessionFrame(target: target, payload: .text(TextPayload(text: text)))
    }
}
#endif
