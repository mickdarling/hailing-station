import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

final class ProgressTestClock: Sendable {
    private struct State {
        var now = ContinuousClock.now
        var waiters: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = [:]
        var cancelled: Set<UUID> = []
        var sleeps = 0
    }
    private let state = Mutex(State())
    let scheduled = AsyncStream<ContinuousClock.Instant>.makeStream()
    var now: ContinuousClock.Instant { state.withLock { $0.now } }
    var sleeps: Int { state.withLock { $0.sleeps } }
    var clock: TaskProgressClock {
        .init(now: { self.now }, sleepUntil: { try await self.sleep(until: $0) })
    }

    private func sleep(until due: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { state in
                    state.sleeps += 1
                    if state.cancelled.remove(id) != nil || Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if due <= state.now {
                        continuation.resume()
                    } else {
                        state.waiters[id] = (due, continuation)
                    }
                }
                scheduled.continuation.yield(due)
            }
        } onCancel: {
            self.state.withLock { state in
                if let waiter = state.waiters.removeValue(forKey: id) {
                    waiter.1.resume(throwing: CancellationError())
                } else {
                    state.cancelled.insert(id)
                }
            }
        }
    }

    func advance(by interval: Duration) {
        state.withLock { state in
            state.now += interval
            for (id, waiter) in state.waiters where waiter.0 <= state.now {
                state.waiters.removeValue(forKey: id)
                waiter.1.resume()
            }
        }
    }
}

@Suite struct TaskProgressSchedulerTests {
    func available() -> TaskProgressEnvironment {
        var value = TaskProgressEnvironment()
        (value.connected, value.listening, value.uniqueRecipient) = (true, true, true)
        return value
    }

    @Test func deadlineDriverHasNoIdleWakesAndCoalescesUntilExactCompletion() async throws {
        let clock = ProgressTestClock()
        let events = AsyncStream<TaskProgressWake>.makeStream()
        let scheduler = TaskProgressScheduler(clock: clock.clock) { events.continuation.yield($0) }
        let task = TaskProgressTask(session: "work", binding: "exact-binding")
        var scheduled = clock.scheduled.stream.makeAsyncIterator()
        var wakes = events.stream.makeAsyncIterator()
        #expect(await scheduler.snapshot().task == nil)
        #expect(clock.sleeps == 0)
        #expect(await scheduler.start(task, interval: .seconds(60)))
        #expect(clock.sleeps == 0, "unknown recipient is not an idle model polling loop")
        await scheduler.observe(available())
        let firstDue = try #require(await scheduled.next())
        #expect(firstDue == clock.now.advanced(by: .seconds(60)))
        clock.advance(by: .seconds(60))
        let first = try #require(await wakes.next())
        #expect(first.task == task)
        #expect(await scheduler.permits(first))
        clock.advance(by: .seconds(600))
        #expect(await scheduler.snapshot().outstanding == first)
        #expect(clock.sleeps == 1, "no more timer tasks while a response is outstanding")
        #expect(await scheduler.complete(first))
        let nextDue = try #require(await scheduled.next())
        #expect(nextDue == clock.now.advanced(by: .seconds(60)))
        await scheduler.finish(task: task.id)
        #expect(await scheduler.snapshot().nextDue == nil)
        #expect(await scheduler.permits(first) == false)
    }

    @Test func intervalAndPauseChangesCancelDeadlineAndDoNotCatchUp() async throws {
        let clock = ProgressTestClock()
        let events = AsyncStream<TaskProgressWake>.makeStream()
        let scheduler = TaskProgressScheduler(clock: clock.clock) { events.continuation.yield($0) }
        var scheduled = clock.scheduled.stream.makeAsyncIterator()
        var wakes = events.stream.makeAsyncIterator()
        await scheduler.observe(available())
        let task = TaskProgressTask(session: "work", binding: "exact-binding")
        _ = await scheduler.start(task, interval: .seconds(60))
        _ = try #require(await scheduled.next())
        clock.advance(by: .seconds(30))
        #expect(await scheduler.owner(.interval(.seconds(120))) == .applied)
        #expect(try #require(await scheduled.next()) == clock.now.advanced(by: .seconds(120)))
        #expect(await scheduler.owner(.pause) == .applied)
        clock.advance(by: .seconds(6_000))
        #expect(await scheduler.snapshot().outstanding == nil)
        #expect(await scheduler.owner(.resume) == .applied)
        #expect(try #require(await scheduled.next()) == clock.now.advanced(by: .seconds(120)))
        clock.advance(by: .seconds(120))
        let wake = try #require(await wakes.next())
        #expect(wake.task == task)
        await scheduler.finish(task: task.id)
    }

    @Test func ownerPauseCancelsAnInFlightSolicitationWithoutEndingTheTask() async throws {
        let clock = ProgressTestClock()
        let started = AsyncStream<TaskProgressWake>.makeStream()
        let canceled = AsyncStream<Void>.makeStream()
        let held = AsyncStream<Void>.makeStream()
        let scheduler = TaskProgressScheduler(clock: clock.clock) { wake in
            await withTaskCancellationHandler {
                started.continuation.yield(wake)
                for await _ in held.stream { }
            } onCancel: { canceled.continuation.yield(()) }
        }
        var due = clock.scheduled.stream.makeAsyncIterator()
        var arrivals = started.stream.makeAsyncIterator()
        var cancellations = canceled.stream.makeAsyncIterator()
        await scheduler.observe(available())
        let task = TaskProgressTask(session: "synthetic-task", binding: "synthetic-binding")
        _ = await scheduler.start(task, interval: .seconds(60))
        _ = try #require(await due.next())
        clock.advance(by: .seconds(60))
        _ = try #require(await arrivals.next())
        #expect(await scheduler.owner(.pause) == .applied)
        _ = await cancellations.next()
        #expect(await scheduler.snapshot().task == task)
        #expect(await scheduler.snapshot().pauseReason == .ownerPaused)
        await scheduler.finish(task: task.id)
    }
}
