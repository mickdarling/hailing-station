import Foundation
@testable import HailDaemonKit

/// Synthetic delivery only: records the actual authority received through protocol dispatch.
actor AuthorityRecordingAdapter: ProviderContextDelivering {
    nonisolated let kind = "authority"
    struct Delivery: Sendable {
        let text: String
        let target: String
        let binding: String?
        let context: ProviderTurnContext?
        let authority: DeliveryAuthority?
    }
    private(set) var deliveries: [Delivery] = []

    func listTargets() async throws -> [AdapterTarget] { [.init(name: "a", binding: "binding-a")] }
    func capture(_ target: String) async throws -> String { "" }

    func deliver(_ text: String, to target: String, binding: String?) async throws {
        deliveries.append(Delivery(text: text, target: target, binding: binding, context: nil, authority: nil))
    }

    func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        deliveries.append(Delivery(text: text, target: target, binding: binding, context: context, authority: nil))
    }

    func deliver(_ text: String, to target: String, binding: String?, authority: DeliveryAuthority) async throws {
        try authority.requireCurrent()
        deliveries.append(Delivery(text: text, target: target, binding: binding, context: nil, authority: authority))
    }

    func deliver(
        _ text: String, to target: String, binding: String, context: ProviderTurnContext, authority: DeliveryAuthority
    ) async throws {
        try authority.requireCurrent()
        deliveries.append(Delivery(text: text, target: target, binding: binding,
                                   context: context, authority: authority))
    }

    func requireRecordedAuthorities() throws {
        for delivery in deliveries { try delivery.authority?.requireCurrent() }
    }
}

struct DeliveryAuthorityRig {
    let host: HailHost
    let store: InMemoryPolicyStore
    let context: ProviderTurnContext

    static func make(
        adapter: any Adapter, beforeUpdate: @escaping @Sendable () -> Void = {}
    ) async throws -> Self {
        let registry = Registry()
        try await registry.register(adapter)
        let target = Registry.id(kind: adapter.kind, name: "a")
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")])
        try policy.allow(target, binding: "binding-a", tier: .open)
        let store = InMemoryPolicyStore(policy, beforeUpdate: beforeUpdate)
        let host = try HailHost(registry: registry, sanitizing: .init(newlines: .split), store: store)
        let binding = try ProviderSessionBinding(hostID: "synthetic-host", providerID: adapter.kind,
                                                targetID: target, sessionID: "binding-a")
        let context = ProviderTurnContext(utteranceID: UUID(), connectionID: UUID(), binding: binding)
        return Self(host: host, store: store, context: context)
    }

    func send(_ text: String, contextual: Bool) async throws -> SendOutcome {
        try await host.sendAuthorized(text, policyGeneration: host.targetPolicy.snapshot(for: context.binding.targetID),
                                      from: "test", expectedBinding: nil, context: contextual ? context : nil)
    }
}
