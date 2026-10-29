import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Each blocking actor call uses its own queue, leaving the cooperative pool free to retire and release it.
final class PolicyWriteGate: Sendable {
    let executor = RecipientPublicationExecutor()
    private let gate: RecipientPublicationGate

    init(timeout: DispatchTimeInterval = .seconds(15)) { gate = RecipientPublicationGate(timeout: timeout) }

    func suspend() {
        guard executor.isExecuting else {
            Issue.record("A synchronous policy test hook must run on its dedicated executor")
            return
        }
        // Classify on the test task after draining, so a timeout cannot cascade into authority assertions.
        _ = gate.block(onDedicatedQueue: true)
    }

    func waitUntilSuspended() async throws {
        do { try await gate.waitEntered() } catch { try requireConclusive() }
        try requireConclusive()
    }

    func fire() { gate.release() }

    /// Release and drain before checking the sticky timeout, even if the held operation threw.
    func finish<Value: Sendable, Failure: Error>(_ operation: Task<Value, Failure>) async throws -> Value {
        fire()
        let result = await operation.result
        try requireConclusive()
        return try result.get()
    }

    private func requireConclusive() throws {
        try #require(!gate.timedOut, "The policy test hook timed out before release; the race is inconclusive")
    }
}

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
