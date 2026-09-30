import Foundation
import Testing
@testable import HailDaemonKit

struct ObservedRig: Sendable {
    let adapter: ObservedAdapter
    let host: HailHost
    let store: InMemoryPolicyStore
    let clock = ObservedClock()
    static let target = "observed:session"
    static func make(
        capture: Bool = true, tier: Tier = .open, adapter: ObservedAdapter = .init()
    ) async throws -> Self {
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow(target, binding: "opaque-observed", tier: tier, capture: capture)
        let store = InMemoryPolicyStore(policy)
        return try Self(adapter: adapter, host: HailHost(registry: registry,
            sanitizing: .init(newlines: .split), store: store), store: store)
    }
    func configuration() -> ProviderObservedSession.Configuration {
        var config = ProviderObservedSession.Configuration()
        config.clock = clock.clock
        return config
    }
    func revoke() throws { _ = try store.update { $0.deny(Self.target) } }
    func sent(_ outcome: ProviderInputOutcome) throws -> ProviderTurnContext {
        guard case .sent(let turn) = outcome else { throw ProviderContractError.unknownTurn }
        return turn
    }
}
