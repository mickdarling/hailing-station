import Synchronization
@testable import HailDaemonKit

/// A `PolicyStore` that keeps the policy in memory and records every save, or fails on demand (#41 tests).
final class InMemoryPolicyStore: PolicyStore, PolicyChangeTracking {
    private struct State {
        var policy: Policy
        var saved: [Policy] = []
        var loadError: (any Error)?
        var saveError: (any Error)?
        var durabilityFailure: PolicyFileError?
        var returnedPolicy: Policy?
        var revision: Int64 = 0
        var loads = 0
    }

    private let state: Mutex<State>
    let summary = "memory (unsigned)"
    private let beforeUpdate: @Sendable () -> Void

    init(
        _ policy: Policy = Policy(), loadError: (any Error)? = nil, saveError: (any Error)? = nil,
        durabilityFailure: PolicyFileError? = nil, returnedPolicy: Policy? = nil,
        beforeUpdate: @escaping @Sendable () -> Void = {}
    ) {
        self.beforeUpdate = beforeUpdate
        state = Mutex(State(
            policy: policy, loadError: loadError, saveError: saveError,
            durabilityFailure: durabilityFailure, returnedPolicy: returnedPolicy
        ))
    }

    var saved: [Policy] { state.withLock { $0.saved } }
    var stored: Policy { state.withLock { $0.policy } }
    var loads: Int { state.withLock { $0.loads } }

    func identity() -> PolicyFileIdentity {
        state.withLock { PolicyFileIdentity(device: 0, inode: 0, modified: .zero, size: $0.revision) }
    }

    func load() throws -> Policy {
        try state.withLock { state in
            state.loads += 1
            if let error = state.loadError { throw error }
            return state.policy
        }
    }

    func update(_ change: (inout Policy) throws -> Void) throws -> PolicyUpdate {
        beforeUpdate()
        return try state.withLock { state in
            if let error = state.loadError { throw error }
            var policy = state.policy
            try change(&policy)
            guard policy != state.policy else {
                return PolicyUpdate(policy: state.returnedPolicy ?? policy)
            }
            if let error = state.saveError { throw error }
            state.policy = policy
            state.revision += 1
            state.saved.append(policy)
            return PolicyUpdate(
                policy: state.returnedPolicy ?? policy,
                durabilityFailure: state.durabilityFailure
            )
        }
    }

    /// What another process would do: change what is stored behind the host's back.
    func overwrite(_ policy: Policy) {
        state.withLock { $0.policy = policy; $0.revision += 1 }
    }

    func setLoadError(_ error: (any Error)?) {
        state.withLock { $0.loadError = error }
    }
}
