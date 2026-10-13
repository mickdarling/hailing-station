import Foundation
import Synchronization
import Testing
@testable import haild

/// Models the real renderer's early deferred-artifact error while exact child exit is still pending.
private final class DelayedRendererJoin: CoachingRendererJoining {
    private struct State {
        var retired = false, reaped = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    var waitingForExit: Bool { state.withLock { $0.waiter != nil } }
    func requireSuccessfulExit() async throws {
        await withCheckedContinuation { waiter in
            let done = state.withLock { current in
                if current.reaped { return true }
                current.waiter = waiter; return false
            }
            if done { waiter.resume() }
        }
        throw CancellationError()
    }
    func retire(cancel: Bool) { state.withLock { $0.retired = true } }
    func waitForCleanup() async throws { throw CancellationError() }
    func waitForCancellationSignals() async {}
    func reap() {
        let waiter = state.withLock { current in
            current.reaped = true
            defer { current.waiter = nil }
            return current.waiter
        }
        waiter?.resume()
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct CoachingRendererJoinTests {
    @Test func earlyDeferredCleanupAndSubmittedSignalsCannotReleaseOwnedChildJoin() async throws {
        let renderer = DelayedRendererJoin(); var returned = false
        let task = Task {
            defer { returned = true }
            try await CoachingRendererCleanup.join(renderer, cancel: true)
        }
        for _ in 0..<100 where !renderer.waitingForExit && !returned { await Task.yield() }
        #expect(renderer.waitingForExit && !returned)
        renderer.reap()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(returned)
    }
}
