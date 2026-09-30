import Foundation
import Dispatch
import Synchronization
@testable import HailDaemonKit

/// A trusted fixture profile; the synchronous getter is gated to exercise Registry's real actor suspension.
final class InputShapeProfile: Sendable {
    private struct State { var shape: AdapterInputShape; var held = false }
    private let state: Mutex<State>
    private let releaseGate = DispatchSemaphore(value: 0)
    let arrivals = ObservedCounter()
    init(_ shape: AdapterInputShape = .singleLineContextual) { state = Mutex(State(shape: shape)) }
    func value() -> AdapterInputShape {
        let held = state.withLock { state in let held = state.held; state.held = false; return held }
        if held { arrivals.increment(); releaseGate.wait() }
        return state.withLock { $0.shape }
    }
    func set(_ shape: AdapterInputShape) { state.withLock { $0.shape = shape } }
    func hold() { state.withLock { $0.held = true } }
    func release() { releaseGate.signal() }
}

actor InputShapeAdapter: ProviderContextDelivering {
    nonisolated let kind = "shape"
    nonisolated let profile: InputShapeProfile
    nonisolated var inputShape: AdapterInputShape { profile.value() }
    private var binding = "opaque-shape"
    private(set) var legacy: [String] = []
    private(set) var contextual: [SyntheticContextAdapter.Delivery] = []
    private let cancelsAtEntry: Bool
    private let failAfter: Int?
    init(profile: InputShapeProfile = .init(), cancelsAtEntry: Bool = false, failAfter: Int? = nil) {
        self.profile = profile; self.cancelsAtEntry = cancelsAtEntry; self.failAfter = failAfter
    }
    func listTargets() async throws -> [AdapterTarget] { [.init(name: "session", binding: binding)] }
    func capture(_ target: String) async throws -> String { "" }
    func rebind() { binding = "replacement" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        guard binding == self.binding else { throw AdapterError.rebound(target) }
        legacy.append(text)
    }
    func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        guard binding == self.binding else { throw AdapterError.rebound(target) }
        if let failAfter, contextual.count >= failAfter { throw ProviderCoordinatorSyntheticError.arbitraryFailure }
        if cancelsAtEntry { withUnsafeCurrentTask { $0?.cancel() } }
        contextual.append(.init(text: text, target: target, binding: binding, context: context))
    }
}

actor InputShapeUnsupportedAdapter: Adapter {
    nonisolated let kind = "shape"
    nonisolated let inputShape: AdapterInputShape = .singleLineContextual
    private(set) var writes: [String] = []
    func listTargets() async throws -> [AdapterTarget] { [.init(name: "session", binding: "opaque-shape")] }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws { writes.append(text) }
}

struct InputShapeRig: Sendable {
    let host: HailHost
    let store: InMemoryPolicyStore
    let context: ProviderTurnContext
    let coordinator: ProviderInputCoordinator
    static let target = "shape:session"
    static func make(
        adapter: any Adapter, tier: Tier = .open, rate: Int = 30,
        sanitizing: SanitizePolicy = .init(newlines: .split), maxTurns: Int = 128
    ) async throws -> Self {
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(deliveriesPerMinute: rate)
        try policy.allow(target, binding: "opaque-shape", tier: tier)
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, sanitizing: sanitizing, store: store)
        let binding = try ProviderSessionBinding(hostID: "synthetic-host", providerID: "shape",
                                                targetID: target, sessionID: "opaque-shape")
        let context = ProviderTurnContext(utteranceID: UUID(), connectionID: UUID(), binding: binding)
        let coordinator = try ProviderInputCoordinator(
            host: host, binding: binding, connectionID: context.connectionID,
            configuration: .init(maxTurns: maxTurns, deliveryMode: .contextual)
        )
        return Self(host: host, store: store, context: context, coordinator: coordinator)
    }
    func readBack(_ text: String) async throws -> ReadBack {
        guard case .needsConfirmation(let readBack) = try await host.send(text, context: context) else {
            throw ProviderContractError.unknownTurn
        }
        return readBack
    }
}
