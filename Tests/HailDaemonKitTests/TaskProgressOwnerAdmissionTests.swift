import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1))) struct TaskProgressOwnerAdmissionTests {
    @Test func refusalCannotChangeCadenceAndExistingOwnerBehaviourStillWorks() async {
        let clock = ProgressTestClock()
        let scheduler = TaskProgressScheduler(clock: clock.clock) { _ in }
        let task = TaskProgressTask(session: "synthetic-task", binding: "synthetic-binding")
        _ = await scheduler.start(task, interval: .seconds(60))
        #expect(await scheduler.owner(.interval(.seconds(90)), task: task,
                                      admission: OwnerTestAdmission(allowed: false)) == .noTask)
        #expect(await scheduler.snapshot().interval == .seconds(60))
        #expect(await scheduler.snapshot().setByOwner == false)
        #expect(await scheduler.owner(.interval(.seconds(90)), task: task,
                                      admission: OwnerTestAdmission(allowed: true)) == .applied)
        #expect(await scheduler.snapshot().interval == .seconds(90))
        #expect(await scheduler.owner(.pause) == .applied)
        #expect(await scheduler.snapshot().pauseReason == .ownerPaused)
        #expect(await scheduler.owner(.resume) == .applied)
        #expect(await scheduler.snapshot().pauseReason == .disconnected)
        await scheduler.finish(task: task.id)
    }

    @Test func queuedControlCannotMutateAReplacementTask() async throws {
        let scheduler = TaskProgressScheduler(clock: ProgressTestClock().clock) { _ in }
        let old = TaskProgressTask(session: "synthetic-old", binding: "synthetic-binding")
        let replacement = TaskProgressTask(session: "synthetic-new", binding: "synthetic-binding")
        _ = await scheduler.start(old, interval: .seconds(60))
        let barrier = OwnerAdmissionTestBarrier()
        defer { barrier.release() }
        try await TaskProgressOwnerAdmissionScope.$beforeAdmission.withValue({ await barrier.hold($0) }, operation: {
            let control = Task { await scheduler.owner(.stop, task: old, admission: OwnerTestAdmission(allowed: true)) }
            defer { control.cancel() }
            var entered = barrier.entered.stream.makeAsyncIterator()
            let enteredID = try #require(await entered.next())
            #expect(enteredID == old.id)
            await scheduler.finish(task: old.id)
            _ = await scheduler.start(replacement, interval: .seconds(120))
            barrier.release()
            #expect(await control.value == .noTask)
            let snapshot = await scheduler.snapshot()
            #expect(snapshot.task == replacement && snapshot.interval == .seconds(120))
            #expect(snapshot.setByOwner == false && snapshot.pauseReason == .disconnected)
            await scheduler.finish(task: replacement.id)
        })
    }

    @Test func dispatchCancellationRunsOnlyAfterAdmissionUnlocks() async throws {
        let clock = ProgressTestClock(), gate = OwnerTestAdmission(allowed: true)
        let started = AsyncStream<Void>.makeStream(), held = AsyncStream<Void>.makeStream()
        let canceled = AsyncStream<Bool>.makeStream()
        let scheduler = TaskProgressScheduler(clock: clock.clock) { _ in
            await withTaskCancellationHandler {
                started.continuation.yield(())
                for await _ in held.stream { }
            } onCancel: { canceled.continuation.yield(gate.isInside) }
        }
        defer { held.continuation.finish() }
        let task = TaskProgressTask(session: "synthetic-work", binding: "synthetic-binding")
        await scheduler.observe(ProgressDispatchTestRig.available())
        _ = await scheduler.start(task, interval: .seconds(60))
        var deadlines = clock.scheduled.stream.makeAsyncIterator()
        _ = try #require(await deadlines.next())
        clock.advance(by: .seconds(60))
        var arrivals = started.stream.makeAsyncIterator()
        _ = try #require(await arrivals.next())
        #expect(await scheduler.owner(.pause, task: task, admission: gate) == .applied)
        var cancellations = canceled.stream.makeAsyncIterator()
        guard let inside = await cancellations.next() else {
            Issue.record("The admitted dispatch did not report cancellation")
            throw CancellationError()
        }
        #expect(inside == false)
        #expect(await scheduler.snapshot().outstanding?.task == task)
        await scheduler.finish(task: task.id)
    }
}
