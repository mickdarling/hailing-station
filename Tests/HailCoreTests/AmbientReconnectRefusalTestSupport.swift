import Foundation
import Testing
@testable import HailCore

/// Cancellation deliberately does not release an obsolete retry; the test or watchdog owns its completion.
@MainActor
final class AmbientRefusalSteps {
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var closed = false
    private(set) var started = 0
    private(set) var completed = 0

    func sleep(_ duration: Duration) async throws {
        _ = duration
        guard !closed else { throw CancellationError() }
        let index: Int = started
        started += 1
        try await withCheckedThrowingContinuation { waiters[index] = $0
            deadlines[index] = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let waiter = waiters.removeValue(forKey: index) else { return }
                deadlines.removeValue(forKey: index)
                Issue.record("Refusal fixture sleeper exceeded its 10-second deadline")
                waiter.resume(throwing: CancellationError())
            }
        }
        completed += 1
    }

    func release(_ index: Int) {
        deadlines.removeValue(forKey: index)?.cancel()
        waiters.removeValue(forKey: index)?.resume()
    }

    func releaseAll() {
        closed = true
        for index in Array(waiters.keys) { release(index) }
    }
}

@MainActor
private final class AmbientRefusalCompletion {
    var result: Result<Void, any Error>?
}

/// An unstructured task lets the deadline return even if the operation ignores cancellation.
@MainActor
func ambientRefusalDeadline(
    timeout: Duration = .seconds(10), operation: @escaping @MainActor () async throws -> Void
) async throws {
    let completion: AmbientRefusalCompletion = AmbientRefusalCompletion()
    let task: Task<Void, Never> = Task { @MainActor in
        do { try await operation(); completion.result = .success(()) } catch {
            completion.result = .failure(error)
        }
    }
    defer { task.cancel() }
    // The condition only reads local state; it cannot itself hang on the operation being joined.
    try await waitUntil(timeout: timeout) { @MainActor in completion.result != nil }
    let result: Result<Void, any Error> = try #require(completion.result)
    try result.get()
}

@MainActor
func withAmbientRefusalRig(
    _ operation: @escaping @MainActor (AmbientReconnectRig, AmbientRefusalSteps) async throws -> Void
) async throws {
    let steps: AmbientRefusalSteps = AmbientRefusalSteps()
    let rig: AmbientReconnectRig = try AmbientReconnectRig(retrySleep: { try await steps.sleep($0) })
    let result: Result<Void, any Error>
    do {
        defer { steps.releaseAll() }
        try await ambientRefusalDeadline(timeout: .seconds(40)) { try await operation(rig, steps) }
        result = .success(())
    } catch { result = .failure(error) }
    try await ambientRefusalDeadline { await rig.close() }
    try result.get()
}

extension AmbientReconnectRig {
    func restoreForRefusal(steps: AmbientRefusalSteps, retryIndex: Int) async throws {
        socket = ScriptedSocket()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        steps.release(retryIndex)
        try await handshake(socket)
        try await select(restoring: true)
        try await feed()
        #expect(notices.last?.outcome == .applied)
    }
}
