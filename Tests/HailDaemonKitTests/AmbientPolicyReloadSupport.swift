import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Captures bytes from the old open descriptor, then pauses decoding while the real CLI renames a new policy.
struct PolicyReloadStore: PolicyChangeTracking {
    final class Hook: Sendable {
        private let pending = Mutex<PolicyWriteGate?>(nil)

        func arm(_ gate: PolicyWriteGate) { pending.withLock { $0 = gate } }

        func beforeDecode() {
            let gate = pending.withLock { value in
                let gate = value
                value = nil
                return gate
            }
            gate?.suspend()
        }
    }

    let file: PolicyFile
    let hook: Hook
    var summary: String { file.summary }
    func identity() throws -> PolicyFileIdentity { try file.identity() }
    func load() throws -> Policy { try file.load(beforeDecode: { hook.beforeDecode() }) }
    func update(_ change: (inout Policy) throws -> Void) throws -> PolicyUpdate { try file.update(change) }
}

extension AmbientAudioGate {
    /// A whole synchronous actor turn, on a dedicated executor, keeps admission queued until the CLI exits.
    func holdPolicyAdmission(_ gate: PolicyWriteGate) { gate.suspend() }
}

extension HostSession {
    /// Opening records its attempted grant immediately before awaiting the gate, so this proves it is queued.
    func waitForPolicyAdmission() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if ambientPolicyGeneration?.wasGranted == true, ambientPolicyStream == nil { return }
            await Task.yield()
        }
        Issue.record("The segment did not queue at admission within its bound")
        throw RecipientPublicationTestError.admissionTimedOut
    }
}
