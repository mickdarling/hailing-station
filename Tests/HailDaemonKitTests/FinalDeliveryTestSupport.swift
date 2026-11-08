import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

actor FinalDeliveryBarrier {
    private var armed = false
    private var arrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func arm() { armed = true }
    func pause() async {
        guard armed else { return }
        armed = false
        arrived = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { release = $0 }
    }
    func wait() async {
        if arrived { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func resume() { release?.resume(); release = nil }
}

actor FinalDeliveryAdapter: ProviderContextDelivering, ProviderReplyBindingLeasing {
    nonisolated let kind = "final"
    nonisolated let leaseAuthority = ReplyPublicationAuthority()
    let listing = FinalDeliveryBarrier()
    let handoff = FinalDeliveryBarrier()
    private(set) var deliveries: [String] = []
    private(set) var contexts: [ProviderTurnContext] = []

    func listTargets() async throws -> [AdapterTarget] {
        await listing.pause()
        return [AdapterTarget(name: "reply", binding: "synthetic-binding")]
    }
    func capture(_ target: String) async throws -> String { "" }
    func acquireReplyBindingLease(_ binding: ProviderSessionBinding) async throws -> ProviderReplyBindingLease {
        ProviderReplyBindingLease(binding: binding, permit: leaseAuthority.issuePermit())
    }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        deliveries.append(text)
    }
    func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        deliveries.append(text)
        contexts.append(context)
    }
    func deliver(_ text: String, to target: String, binding: String?, authority: DeliveryAuthority) async throws {
        await handoff.pause()
        try authority.requireCurrent()
        deliveries.append(text)
    }
    func deliver(
        _ text: String, to target: String, binding: String, context: ProviderTurnContext, authority: DeliveryAuthority
    ) async throws {
        await handoff.pause()
        try authority.requireCurrent()
        deliveries.append(text)
        contexts.append(context)
    }
}

struct FinalDeliveryLegacyAdapter: Adapter {
    let kind = "final"
    let adapter: FinalDeliveryAdapter
    func listTargets() async throws -> [AdapterTarget] { try await adapter.listTargets() }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        try await adapter.deliver(text, to: target, binding: binding)
    }
    func deliver(_ text: String, to target: String, binding: String?, authority: DeliveryAuthority) async throws {
        try await adapter.deliver(text, to: target, binding: binding, authority: authority)
    }
}

struct FinalDeliveryRig {
    static let target = "final:reply"
    let adapter: FinalDeliveryAdapter
    let host: HailHost
    let listener: WebSocketListener
    let session: HostSession
    let peer: WebSocketPeer
    let clock: RecipientTestClock
    let id: UUID

    static func make(legacy: Bool = false, held: Bool = false) async throws -> Self {
        let adapter = FinalDeliveryAdapter(), registry = Registry(), clock = RecipientTestClock()
        if legacy {
            try await registry.register(FinalDeliveryLegacyAdapter(adapter: adapter))
        } else {
            try await registry.register(adapter)
        }
        var policy = Policy(guardPatterns: [
            .init(name: "synthetic guard", regex: held ? "^synthetic input$" : "^synthetic guarded command$")
        ])
        try policy.allow(target, binding: "synthetic-binding", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy), requestNow: clock.instant)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "synthetic-host",
                                  requestClock: clock.instant)
        _ = await session.receive(helloFrame(capabilities: held ? [HeldRequests.capability] : []))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
                                             authorizer: PersonalTerminalAuthorizer())
        let peer = try #require(await listener.installFallbackSyntheticPeers([session]).first)
        let id = try #require(await listener.connectionID(of: peer))
        return Self(adapter: adapter, host: host, listener: listener, session: session, peer: peer,
                    clock: clock, id: id)
    }

    func ambient(reference: UUID? = nil) async throws -> UUID? {
        try await listener.dispatchAmbient(
            dispatchRequest(connection: session.connectionID, target: Self.target, binding: "synthetic-binding"),
            reference: reference, selection: await session.selectionGeneration
        )
    }

    func hold() async throws -> UUID {
        let result = try await listener.dispatchAmbientResult(
            dispatchRequest(connection: session.connectionID, target: Self.target, binding: "synthetic-binding"),
            selection: await session.selectionGeneration
        )
        guard case .held(let notice) = result else { throw HeldTestError.expectedHold }
        return notice.held
    }

    func expectEmpty() async {
        let ledger = await listener.lastInput
        #expect(await adapter.deliveries.isEmpty)
        #expect(await adapter.contexts.isEmpty)
        #expect(await session.replyRequests.isEmpty)
        #expect(await session.evictedForHandoff.isEmpty)
        #expect(ledger.latest(for: Self.target) == nil)
    }
}
