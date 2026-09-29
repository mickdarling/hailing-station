import Foundation
@testable import HailDaemonKit

/// Only invented session labels/output; observation is owned by the test, not a host driver.
actor SyntheticContextAdapter: ProviderContextDelivering, ProviderSessionObserving {
    nonisolated let kind = "test"
    nonisolated let observationCapabilities: Set<ProviderObservationCapability> = [
        .explicitAcceptance, .userVisibleText, .explicitCompletion
    ]
    struct Delivery: Sendable, Equatable {
        let text: String
        let target: String
        let binding: String
        let context: ProviderTurnContext
    }

    private var targets = [ProviderContextTestRig.target]
    private var channel: ProviderEventChannel?
    private var observationBinding: ProviderSessionBinding?
    private var sequence = 0
    private let error: (any Error)?
    private let failAfter: Int?
    private var held = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var contextual: [Delivery] = []
    private(set) var legacy: [String] = []
    private(set) var observationCount = 0

    init(error: (any Error)? = nil, failAfter: Int? = nil) {
        self.error = error
        self.failAfter = failAfter
    }

    func listTargets() async throws -> [AdapterTarget] { targets }
    func setTargets(_ targets: [AdapterTarget]) { self.targets = targets }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws { legacy.append(text) }

    func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        guard targets.contains(where: { $0.name == target && $0.binding == binding }) else {
            throw AdapterError.rebound(target)
        }
        if let error { throw error }
        if let failAfter, contextual.count >= failAfter { throw ProviderCoordinatorSyntheticError.arbitraryFailure }
        contextual.append(Delivery(text: text, target: target, binding: binding, context: context))
        // The adapter emits its own events from the submitted context, before dispatch returns.
        if observationBinding == context.binding, let channel {
            for kind in [ProviderEventKind.accepted,
                         .text("synthetic provider output", isFinal: true, visibility: .userVisible), .finished] {
                let event = try ProviderSessionEvent(binding: context.binding, sequence: sequence,
                                                     turn: context, kind: kind)
                sequence += 1
                channel.yield(event)
            }
        }
        if held {
            arrival?.resume()
            arrival = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    func observe(_ binding: ProviderSessionBinding) async throws -> ProviderObservation {
        observationCount += 1
        let channel = try ProviderEventChannel(capacity: 32)
        self.channel = channel
        observationBinding = binding
        return channel.observation
    }

    func holdDispatch() { held = true }
    func waitForDispatch() async {
        if releaseWaiter != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func releaseDispatch() {
        held = false
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

struct ProviderContextTestRig {
    let host: HailHost
    let store: InMemoryPolicyStore
    let coordinator: ProviderInputCoordinator
    let context: ProviderTurnContext
    var binding: ProviderSessionBinding { context.binding }
    static var target: AdapterTarget { AdapterTarget(name: "session", binding: "binding-test") }

    static func make(
        adapter: any Adapter = SyntheticContextAdapter(), tier: Tier = .open,
        mode: ProviderInputDeliveryMode = .contextual, sanitizing: SanitizePolicy = .init(), rate: Int = 30
    ) async throws -> Self {
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(deliveriesPerMinute: rate)
        try policy.allow("test:session", binding: "binding-test", tier: tier)
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, sanitizing: sanitizing, store: store)
        let binding = try ProviderSessionBinding(
            hostID: "host-test", providerID: "test", targetID: "test:session", sessionID: "binding-test"
        )
        let context = ProviderTurnContext(utteranceID: UUID(), connectionID: UUID(), binding: binding)
        let coordinator = try ProviderInputCoordinator(
            host: host, binding: binding, connectionID: context.connectionID,
            configuration: .init(maxTurns: 2, deliveryMode: mode)
        )
        return Self(host: host, store: store, coordinator: coordinator, context: context)
    }

    func submit(_ text: String = "synthetic input") async throws -> ProviderTurnContext {
        let outcome = try await coordinator.submit(text, utteranceID: context.utteranceID)
        guard case .sent(let context) = outcome else { throw ProviderContractError.unknownTurn }
        return context
    }
}
