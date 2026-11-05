import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1))) struct TaskProgressDispatchCancellationTests {
    @Test(arguments: [ProgressDispatchCancellation.ownerPause, .ownerStop, .privacy])
    func cancellationBeforeCallbackRetiresOnlyTheUnissuedToken(_ cause: ProgressDispatchCancellation) async throws {
        try await withRig(holding: true) { rig in
            let unissued = try await cancelBeforeCallback(rig, cause: cause)
            #expect(try await rig.nextDue() == rig.clock.now.advanced(by: .seconds(60)))
            rig.clock.advance(by: .seconds(60))
            let current = try await rig.callbacks.next()
            #expect(try await rig.finished.next() == current)
            #expect(current.task == unissued.task && current.token != unissued.token)
            #expect(await rig.scheduler.permits(current))
            #expect(await rig.scheduler.complete(unissued) == false, "stale completion cannot release the fresh wake")
            rig.clock.advance(by: .seconds(600))
            #expect(await rig.scheduler.snapshot().outstanding == current)
            #expect(await rig.scheduler.snapshot().nextDue == nil)
            #expect(rig.callbacks.count == 1 && rig.clock.sleeps == 2)
            #expect(await rig.scheduler.complete(current))
            #expect(try await rig.nextDue() == rig.clock.now.advanced(by: .seconds(60)))
        }
    }

    private func cancelBeforeCallback(
        _ rig: ProgressDispatchTestRig, cause: ProgressDispatchCancellation
    ) async throws -> TaskProgressWake {
        try await rig.start()
        rig.clock.advance(by: .seconds(60))
        let unissued = try await rig.barrier.entered.next()
        #expect(await rig.scheduler.snapshot().outstanding == unissued)
        await cause.pause(rig.scheduler)
        #expect(await rig.scheduler.snapshot().pauseReason == cause.reason)
        rig.clock.advance(by: .seconds(600))
        await cause.resume(rig.scheduler)
        #expect(await rig.scheduler.snapshot().outstanding == unissued,
                "pause/resume must not blanket-clear an outstanding token")
        #expect(await rig.scheduler.snapshot().nextDue == nil)
        #expect(rig.callbacks.isEmpty)
        rig.barrier.release()
        #expect(try await rig.finished.next() == unissued)
        let retired = await rig.scheduler.snapshot()
        try #require(retired.outstanding == nil, "a callback that never entered cannot supply an external completion")
        #expect(retired.nextDue == rig.clock.now.advanced(by: .seconds(60)))
        #expect(await rig.scheduler.permits(unissued) == false)
        #expect(rig.callbacks.isEmpty, "the canceled unissued wake must never invoke the callback")
        return unissued
    }

    @Test func callbackReturnAndPauseResumeKeepAcceptedWorkBusyUntilItsExactReport() async throws {
        try await withRig(holding: false) { rig in
            try await rig.start()
            rig.clock.advance(by: .seconds(60))
            let accepted = try await rig.callbacks.next()
            #expect(try await rig.finished.next() == accepted, "the callback has returned before the pause")
            #expect(await rig.scheduler.owner(.pause) == .applied)
            #expect(await rig.scheduler.snapshot().outstanding == accepted)
            #expect(await rig.scheduler.owner(.resume) == .applied)
            var privateState = ProgressDispatchTestRig.available()
            privateState.privateMode = true
            await rig.scheduler.observe(privateState)
            await rig.scheduler.observe(ProgressDispatchTestRig.available())
            rig.clock.advance(by: .seconds(6_000))
            #expect(await rig.scheduler.snapshot().outstanding == accepted)
            #expect(await rig.scheduler.snapshot().pauseReason == .outstanding)
            #expect(await rig.scheduler.snapshot().nextDue == nil)
            #expect(rig.callbacks.count == 1 && rig.clock.sleeps == 1)
            #expect(await rig.scheduler.complete(accepted))
            #expect(try await rig.nextDue() == rig.clock.now.advanced(by: .seconds(60)))
        }
    }

    private func withRig(
        holding: Bool, operation: (ProgressDispatchTestRig) async throws -> Void
    ) async throws {
        let rig = ProgressDispatchTestRig()
        defer { rig.barrier.release() }
        do {
            try await TaskProgressDispatchScope.$hooks.withValue(rig.hooks(holding: holding)) {
                try await operation(rig)
            }
            await rig.finish()
        } catch {
            await rig.finish()
            throw error
        }
    }
}
