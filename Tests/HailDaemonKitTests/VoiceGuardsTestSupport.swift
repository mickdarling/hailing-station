import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

final class VoiceGuardsLog: Sendable {
    private let entries = Mutex<[String]>([])
    var lines: [String] { entries.withLock { $0 } }
    func record(_ line: String) { entries.withLock { $0.append(line) } }
    func object() throws -> [String: Any] {
        let line = try #require(lines.first)
        return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

/// Real session selection, authorization, routing and listener ambient dispatch, with never-started transports.
struct VoiceGuardsRoute {
    static let words = "synthetic guarded command"
    static let rule = GuardPattern(name: "synthetic rule", regex: "synthetic guarded command")
    let host: HailHost
    let store: InMemoryPolicyStore
    let session: HostSession
    let listener: WebSocketListener
    let peer: WebSocketPeer
    let log: VoiceGuardsLog
    let target: String
    let binding: String

    static func make(
        adapter: any Adapter, target: String = "final:reply", binding: String = "synthetic-binding",
        policy: Policy = Policy(guardPatterns: [rule], voiceGuards: .off),
        sanitizing: SanitizePolicy = .init(), capabilities: [String] = ["probe"],
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) async throws -> Self {
        let registry = Registry(), log = VoiceGuardsLog()
        try await registry.register(adapter)
        var policy = policy
        if policy.targets[target] == nil { try policy.allow(target, binding: binding, tier: .open) }
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, sanitizing: sanitizing, store: store, requestNow: now,
                                voiceGuardLog: log.record)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "synthetic-host",
                                  requestClock: now)
        _ = await session.receive(helloFrame(capabilities: capabilities))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
                                             authorizer: PersonalTerminalAuthorizer(), hostName: "synthetic-host")
        let peer = try #require(await listener.installFallbackSyntheticPeers([session]).first)
        return Self(host: host, store: store, session: session, listener: listener, peer: peer, log: log,
                    target: target, binding: binding)
    }

    func ambient(_ text: String = words) async throws -> UUID? {
        let dispatcher = AmbientListenerDispatcher(listener: listener, audit: nil,
            selection: await session.selectionGeneration, streamTarget: target)
        return try await dispatcher.dispatch(await request(text), routed: false)
    }

    func request(_ text: String = words) async -> LocalDispatchRequest {
        LocalDispatchRequest(connection: await session.connectionID, target: target, binding: binding, text: text)
    }

    func setPolicy(_ change: (inout Policy) -> Void) {
        var policy = store.stored
        change(&policy)
        store.overwrite(policy)
    }
}
