import Foundation
import Synchronization
@testable import HailDaemonKit

actor CallPolicyAdapter: Adapter {
    nonisolated let kind = "tmux"

    func listTargets() async throws -> [AdapterTarget] {
        [AdapterTarget(name: "synthetic", binding: "synthetic-binding")]
    }

    func deliver(_ text: String, to target: String, binding: String?) async throws {}

    func capture(_ target: String) async throws -> String {
        ""
    }
}

final class CallPolicyStore: PolicyStore {
    let state: Mutex<Policy>
    let summary = "synthetic memory policy"

    init(_ policy: Policy) {
        state = Mutex(policy)
    }

    func load() throws -> Policy {
        state.withLock { $0 }
    }

    func update(_ change: (inout Policy) throws -> Void) throws -> PolicyUpdate {
        try state.withLock { policy in
            try change(&policy)
            return PolicyUpdate(policy: policy)
        }
    }
}
