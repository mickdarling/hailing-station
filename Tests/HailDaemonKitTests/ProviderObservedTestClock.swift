import Foundation
import Synchronization
@testable import HailDaemonKit

final class ObservedCounter: Sendable {
    private struct State {
        var count = 0
        var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }
    private let state = Mutex(State())
    var count: Int { state.withLock { $0.count } }
    func increment() {
        let ready = state.withLock { state in
            state.count += 1
            let ready = state.waiters.filter { $0.0 <= state.count }.map(\.1)
            state.waiters.removeAll { $0.0 <= state.count }
            return ready
        }
        ready.forEach { $0.resume() }
    }
    func wait(for count: Int = 1) async {
        await withCheckedContinuation { waiter in
            let ready = state.withLock { state in
                if state.count >= count { return true }
                state.waiters.append((count, waiter)); return false
            }
            if ready { waiter.resume() }
        }
    }
}

actor ObservedGate {
    nonisolated let arrivals = ObservedCounter()
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation = $0; arrivals.increment() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

actor ObservedPoll {
    nonisolated let sleeps = ObservedCounter()
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<UUID> = []
    func sleep() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled || cancelled.remove(id) != nil {
                    waiter.resume(throwing: CancellationError())
                } else {
                    waiters[id] = waiter; sleeps.increment()
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) { waiter.resume(throwing: CancellationError()) } else {
            cancelled.insert(id)
        }
    }
    func tick() {
        let ready = Array(waiters.values); waiters.removeAll()
        ready.forEach { $0.resume() }
    }
}

final class ObservedClock: Sendable {
    private let instant = Mutex(ContinuousClock().now)
    let poll = ObservedPoll()
    var clock: ProviderSessionClock {
        var clock = ProviderSessionClock()
        clock.now = { self.instant.withLock { $0 } }
        clock.sleep = { _ in try await self.poll.sleep() }
        return clock
    }
    func advance(_ duration: Duration) async {
        instant.withLock { $0 = $0.advanced(by: duration) }
        await poll.tick()
    }
}
