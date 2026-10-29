import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

enum SelectionPreflightWaitError: Error, Equatable {
    case deadline(String)
    case dispatchEndedBeforeListing
}

/// A single-use, sticky result: timeout, cancellation and close all remove and resume the waiter.
final class SelectionPreflightSignal<Value: Sendable>: Sendable {
    private let state = Mutex((
        result: Result<Value, any Error>?.none,
        waiter: CheckedContinuation<Value, any Error>?.none
    ))

    var hasWaiter: Bool { state.withLock { $0.waiter != nil } }

    func finish(_ result: Result<Value, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: result)
    }

    func wait(_ label: String, timeout: Duration = .seconds(5)) async throws -> Value {
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            finish(.failure(SelectionPreflightWaitError.deadline(label)))
        }
        defer { deadline.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let result = state.withLock { state -> Result<Value, any Error>? in
                        if let result = state.result { return result }
                        state.waiter = continuation
                        return nil
                    }
                    if let result { continuation.resume(with: result) }
                }
            } onCancel: {
                self.finish(.failure(CancellationError()))
            }
        } catch {
            if error is SelectionPreflightWaitError { Issue.record("Selection preflight wait failed: \(error)") }
            throw error
        }
    }
}

/// Unstructured work lets the deadline return even when an actor hop or Task.value ignores cancellation.
func selectionPreflightStep<Value: Sendable>(
    _ label: String, timeout: Duration = .seconds(5),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let completion = SelectionPreflightSignal<Value>()
    let work = Task {
        do { completion.finish(.success(try await operation())) } catch { completion.finish(.failure(error)) }
    }
    defer { work.cancel() }
    return try await completion.wait(label, timeout: timeout)
}

/// Synchronous policy I/O parks only on a dedicated executor; its async entry handshake is cancellable.
final class SelectionPreflightLoadGate: Sendable {
    let executor = RecipientPublicationExecutor()
    private let entered = SelectionPreflightSignal<Void>()
    private let gate = RecipientPublicationGate(timeout: .seconds(15))

    var hasEntryWaiter: Bool { entered.hasWaiter }

    func suspend() {
        guard executor.isExecuting else {
            Issue.record("The selection preflight policy hook must use its dedicated executor")
            entered.finish(.failure(CancellationError()))
            return
        }
        entered.finish(.success(()))
        if !gate.block(onDedicatedQueue: true) {
            Issue.record("The selection preflight policy hook timed out before release")
        }
    }

    func waitUntilSuspended() async throws {
        try await entered.wait("policy load entry")
        try #require(!gate.timedOut)
    }

    func fire() {
        gate.release()
        entered.finish(.failure(CancellationError()))
    }
}

final class SelectionPreflightListing: Sendable {
    let arrival = SelectionPreflightSignal<Void>()
    private let released = SelectionPreflightSignal<Void>()
    private let state = Mutex((armed: false, closed: false))

    func arm() { state.withLock { if !$0.closed { $0.armed = true } } }

    func pauseIfArmed() async throws {
        let armed = state.withLock { state in
            defer { state.armed = false }
            return state.armed && !state.closed
        }
        guard armed else { return }
        arrival.finish(.success(()))
        try await released.wait("listing release")
    }

    func dispatchFinished() { arrival.finish(.failure(SelectionPreflightWaitError.dispatchEndedBeforeListing)) }
    func release() { released.finish(.success(())) }

    func close() {
        state.withLock { $0 = (armed: false, closed: true) }
        arrival.finish(.failure(CancellationError()))
        release()
    }
}

actor SelectionPreflightAdapter: Adapter {
    nonisolated let kind = "tmux"
    private let listing: SelectionPreflightListing
    private(set) var deliveries: [String] = []

    init(listing: SelectionPreflightListing) { self.listing = listing }

    func listTargets() async throws -> [AdapterTarget] {
        try await listing.pauseIfArmed()
        return [AdapterTarget(name: "a", binding: "binding-a")]
    }

    func deliver(_ text: String, to target: String, binding: String?) async throws { deliveries.append(text) }
    func capture(_ target: String) async throws -> String { "" }
}
