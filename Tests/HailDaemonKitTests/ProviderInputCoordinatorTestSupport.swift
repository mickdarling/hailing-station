import Foundation
import Dispatch
import Synchronization
import Testing
@testable import HailDaemonKit

final class ProviderCoordinatorTestClock: Sendable {
    private let instant = Mutex(ContinuousClock().now)

    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
}

struct ProviderCoordinatorRig {
    let binding: ProviderSessionBinding
    let connectionID: UUID
    let host: HailHost
    let coordinator: ProviderInputCoordinator
    let clock: ProviderCoordinatorTestClock

    static func make(
        adapter: any Adapter = FakeAdapter(kind: "tmux", targets: [target]), tier: Tier = .open,
        configuration: ProviderInputCoordinator.Configuration = .init(),
        clock: ProviderCoordinatorTestClock = ProviderCoordinatorTestClock(),
        sanitizing: SanitizePolicy = SanitizePolicy()
    ) async throws -> Self {
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:synthetic", binding: "opaque-binding", tier: tier)
        let host = try HailHost(registry: registry, sanitizing: sanitizing, store: InMemoryPolicyStore(policy))
        let binding = try ProviderSessionBinding(
            hostID: "host-test", providerID: "tmux", targetID: "tmux:synthetic", sessionID: "opaque-binding"
        )
        let connectionID = UUID()
        let coordinator = try ProviderInputCoordinator(
            host: host, binding: binding, connectionID: connectionID, configuration: configuration, now: clock.now
        )
        return Self(binding: binding, connectionID: connectionID, host: host, coordinator: coordinator, clock: clock)
    }

    static var target: AdapterTarget { AdapterTarget(name: "synthetic", binding: "opaque-binding") }

    func send() async throws -> ProviderTurnContext {
        let outcome = try await coordinator.submit("synthetic input", utteranceID: UUID())
        return try context(outcome)
    }

    func context(_ outcome: ProviderInputOutcome) throws -> ProviderTurnContext {
        guard case .sent(let context) = outcome else { throw ProviderContractError.unknownTurn }
        return context
    }

    func event(_ sequence: Int, turn: ProviderTurnContext?, kind: ProviderEventKind) throws -> ProviderSessionEvent {
        try ProviderSessionEvent(binding: binding, sequence: sequence, turn: turn, kind: kind)
    }
}

/// Explicit arrival handshake avoids sleeps and preserves already-arrived notification.
actor ProviderCoordinatorGatedAdapter: Adapter {
    nonisolated let kind = "tmux"
    private var arrived = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var deliveries: [String] = []

    func listTargets() async throws -> [AdapterTarget] { [ProviderCoordinatorRig.target] }
    func capture(_ target: String) async throws -> String { "" }

    func deliver(_ text: String, to target: String, binding: String?) async throws {
        arrived = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        deliveries.append(text)
    }

    func waitForDispatch() async {
        if arrived { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

actor ProviderCoordinatorCancellationAdapter: Adapter {
    nonisolated let kind = "tmux"
    private(set) var deliveries: [String] = []

    func listTargets() async throws -> [AdapterTarget] { [ProviderCoordinatorRig.target] }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        guard deliveries.isEmpty else { throw CancellationError() }
        deliveries.append(text)
    }
}

enum ProviderCoordinatorSyntheticError: Error, Equatable { case arbitraryFailure }

actor ProviderArbitraryFailureAdapter: Adapter {
    nonisolated let kind = "tmux"
    private let successfulWrites: Int
    private(set) var deliveries: [String] = []

    init(successfulWrites: Int) { self.successfulWrites = successfulWrites }
    func listTargets() async throws -> [AdapterTarget] { [ProviderCoordinatorRig.target] }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        guard deliveries.count < successfulWrites else { throw ProviderCoordinatorSyntheticError.arbitraryFailure }
        deliveries.append(text)
    }
}

/// Blocks a synchronous store reload while an async handshake lets the test cancel its caller.
final class ProviderCoordinatorGatedStore: PolicyStore {
    private struct Gate {
        var armed = false
        var arrived = false
        var arrival: CheckedContinuation<Void, Never>?
    }

    private let backing: InMemoryPolicyStore
    private let gate = Mutex(Gate())
    private let releaseGate = DispatchSemaphore(value: 0)
    let summary = "gated synthetic policy"

    init(_ policy: Policy) { backing = InMemoryPolicyStore(policy) }

    func gateNextLoad() { gate.withLock { $0.armed = true; $0.arrived = false } }

    func load() throws -> Policy {
        let blocked = gate.withLock { state in
            guard state.armed else { return false }
            state.armed = false
            state.arrived = true
            state.arrival?.resume()
            state.arrival = nil
            return true
        }
        if blocked { releaseGate.wait() }
        return try backing.load()
    }

    func update(_ change: (inout Policy) throws -> Void) throws -> PolicyUpdate { try backing.update(change) }

    func waitForReload() async {
        await withCheckedContinuation { continuation in
            gate.withLock { state in
                if state.arrived { continuation.resume() } else { state.arrival = continuation }
            }
        }
    }

    func release() { releaseGate.signal() }
}
