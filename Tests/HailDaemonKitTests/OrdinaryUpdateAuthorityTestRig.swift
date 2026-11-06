import Dispatch
import Foundation
import HailProtocol
import Network
import Synchronization
@testable import HailDaemonKit

/// Synthetic transport and registry only; shares a store so tests can model another policy writer.
final class OrdinaryUpdateSendCounter: Sendable {
    private let value = Mutex(0)
    func record() { value.withLock { $0 += 1 } }
    var total: Int { value.withLock { $0 } }
}

struct OrdinaryUpdateAuthorityTestRig: Sendable {
    let store: InMemoryPolicyStore
    let adapter: RecipientContextAdapter
    let host: HailHost
    let session: HostSession
    let listener: WebSocketListener
    let connection: UUID
    let sends: OrdinaryUpdateSendCounter

    static func make() async throws -> Self {
        let adapter = RecipientContextAdapter(), registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow(RecipientTestRig.target, binding: "reply-binding", tier: .open)
        let store = InMemoryPolicyStore(policy), host = try HailHost(registry: registry, store: store)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame(capabilities: [SessionUpdateCard.capability]))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        let sends = OrdinaryUpdateSendCounter()
        let peer = WebSocketPeer(id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: session, queue: DispatchQueue(label: "synthetic.notify.authority"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitReply: { completion in
                sends.record(); completion(nil)
            })
        let connection = await session.connectionID, generation = await session.selectionGeneration
        await listener.enableSessionUpdates()
        await listener.installSessionUpdateTestPeer(peer, connectionID: connection, generation: generation)
        return Self(store: store, adapter: adapter, host: host, session: session, listener: listener,
                    connection: connection, sends: sends)
    }

    var request: LocalSessionUpdateRequest {
        .init(action: .submit, target: RecipientTestRig.target, text: "Synthetic ordinary update from original source")
    }

    func rebind(_ binding: String?) async {
        await adapter.setTargets([AdapterTarget(name: "reply", binding: binding)])
    }
}
