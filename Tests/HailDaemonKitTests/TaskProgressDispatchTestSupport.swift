import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

final class ProgressWakeEvents: Sendable {
    let events = AsyncStream<TaskProgressWake>.makeStream()
    private let values = Mutex<[TaskProgressWake]>([])
    var count: Int { values.withLock { $0.count } }
    var isEmpty: Bool { values.withLock { $0.isEmpty } }

    func record(_ wake: TaskProgressWake) {
        values.withLock { $0.append(wake) }
        events.continuation.yield(wake)
    }

    func next() async throws -> TaskProgressWake {
        var iterator = events.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }
}

/// Cancellation cannot bypass this barrier. Every test releases it synchronously in cleanup.
final class ProgressCallbackBarrier: Sendable {
    private struct State {
        var first = true
        var released = false
        var waiting: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    let entered = ProgressWakeEvents()

    func holdFirst(_ wake: TaskProgressWake) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let held = state.withLock { state in
                guard state.first, !state.released else { return false }
                state.first = false
                state.waiting = continuation
                return true
            }
            if held { entered.record(wake) } else { continuation.resume() }
        }
    }

    func release() {
        let waiting = state.withLock { state in
            state.released = true
            let waiting = state.waiting
            state.waiting = nil
            return waiting
        }
        waiting?.resume()
    }
}

enum ProgressDispatchCancellation: Sendable {
    case ownerPause, ownerStop, privacy

    var reason: TaskProgressPauseReason {
        switch self {
        case .ownerPause: .ownerPaused
        case .ownerStop: .ownerStopped
        case .privacy: .privacy
        }
    }

    func pause(_ scheduler: TaskProgressScheduler) async {
        switch self {
        case .ownerPause: _ = await scheduler.owner(.pause)
        case .ownerStop: _ = await scheduler.owner(.stop)
        case .privacy:
            var environment = ProgressDispatchTestRig.available()
            environment.privateMode = true
            await scheduler.observe(environment)
        }
    }

    func resume(_ scheduler: TaskProgressScheduler) async {
        if case .privacy = self { await scheduler.observe(ProgressDispatchTestRig.available()) } else {
            _ = await scheduler.owner(.resume)
        }
    }
}

final class ProgressDispatchTestRig: Sendable {
    let clock: ProgressTestClock
    let barrier = ProgressCallbackBarrier()
    let callbacks: ProgressWakeEvents
    let finished = ProgressWakeEvents()
    let scheduler: TaskProgressScheduler
    let task = TaskProgressTask(session: "synthetic-work", binding: "synthetic-binding")

    init() {
        let clock = ProgressTestClock()
        let callbacks = ProgressWakeEvents()
        self.clock = clock
        self.callbacks = callbacks
        scheduler = TaskProgressScheduler(clock: clock.clock) { callbacks.record($0) }
    }

    static func available() -> TaskProgressEnvironment {
        var value = TaskProgressEnvironment()
        (value.connected, value.listening, value.uniqueRecipient) = (true, true, true)
        return value
    }

    func hooks(holding: Bool) -> TaskProgressDispatchHooks {
        let barrier = barrier
        let finished = finished
        let beforeCallback: TaskProgressScheduler.Wake?
        if holding { beforeCallback = { await barrier.holdFirst($0) } } else { beforeCallback = nil }
        return .init(beforeCallback: beforeCallback, didFinish: { finished.record($0) })
    }

    func nextDue() async throws -> ContinuousClock.Instant {
        var iterator = clock.scheduled.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    func start() async throws {
        await scheduler.observe(Self.available())
        #expect(await scheduler.start(task, interval: .seconds(60)))
        #expect(try await nextDue() == clock.now.advanced(by: .seconds(60)))
    }

    func finish() async {
        barrier.release()
        await scheduler.finish(task: task.id)
        callbacks.events.continuation.finish()
        finished.events.continuation.finish()
        barrier.entered.events.continuation.finish()
        clock.scheduled.continuation.finish()
    }
}
