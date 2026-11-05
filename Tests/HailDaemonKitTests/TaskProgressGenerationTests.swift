import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1))) struct TaskProgressGenerationTests {
    @Test func lateFinishObserveAndOwnerCannotTouchASameValueSuccessor() async throws {
        let clock = ProgressTestClock(), events = ProgressWakeEvents()
        let scheduler = TaskProgressScheduler(clock: clock.clock) { events.record($0) }
        let task = TaskProgressTask(session: "synthetic-work", binding: "synthetic-binding")
        let old = UUID(), fresh = UUID(), gate = OwnerTestAdmission(allowed: true)
        #expect(await scheduler.start(task, interval: .seconds(60), generation: old,
                                      environment: ProgressDispatchTestRig.available(), admission: gate))
        var deadlines = clock.scheduled.stream.makeAsyncIterator()
        _ = try #require(await deadlines.next())
        clock.advance(by: .seconds(60))
        let oldWake = try await events.next()
        #expect(oldWake.enrollmentGeneration == old)
        let barrier = OwnerAdmissionTestBarrier()
        defer { barrier.release() }
        let finishing = TaskProgressLifetimeScope.$beforeFinish.withValue(
            { _ in await barrier.hold(task) }, operation: {
                Task { await scheduler.finish(task: task, generation: old) }
            }
        )
        defer { finishing.cancel() }
        var entered = barrier.entered.stream.makeAsyncIterator()
        _ = try #require(await entered.next())
        #expect(await scheduler.start(task, interval: .seconds(120), generation: fresh,
                                      environment: ProgressDispatchTestRig.available(), admission: gate))
        barrier.release()
        #expect(await finishing.value == false)
        await assertFresh(scheduler, task: task, old: old, fresh: fresh)
    }

    private func assertFresh(_ scheduler: TaskProgressScheduler, task: TaskProgressTask,
                             old: UUID, fresh: UUID) async {
        var privateState = ProgressDispatchTestRig.available()
        privateState.privateMode = true
        await scheduler.observe(privateState, task: task, generation: old)
        #expect(await scheduler.owner(.stop, task: task, generation: old,
                                      admission: OwnerTestAdmission(allowed: true)) == .noTask)
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.task == task && snapshot.interval == .seconds(120))
        #expect(snapshot.pauseReason == nil && snapshot.setByOwner == false && snapshot.nextDue != nil)
        #expect(await scheduler.finish(task: task, generation: fresh))
        #expect(await scheduler.snapshot().task == nil)
    }

    @Test func refusedGenerationStartCannotInstallTaskOrDeadline() async {
        let clock = ProgressTestClock()
        let scheduler = TaskProgressScheduler(clock: clock.clock) { _ in }
        let task = TaskProgressTask(session: "synthetic-work", binding: "synthetic-binding")
        #expect(await scheduler.start(task, interval: .seconds(60), generation: UUID(),
                                      environment: ProgressDispatchTestRig.available(),
                                      admission: OwnerTestAdmission(allowed: false)) == false)
        #expect(await scheduler.snapshot().task == nil && clock.sleeps == 0)
    }
}
