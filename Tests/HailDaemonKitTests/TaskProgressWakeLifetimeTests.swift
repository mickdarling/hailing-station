import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressWakeLifetimeTests {
    @Test(arguments: LifetimeWakeFailure.allCases, LifetimeSuccessor.allCases)
    func oldNoncooperativeAdapterFailureCannotRetireASameUUIDSuccessor(
        _ failure: LifetimeWakeFailure, _ successor: LifetimeSuccessor
    ) async throws {
        try await withLifetimeWakeRig { rig, finished in
            let adapter = rig.peer.hostRig.adapter
            await adapter.failLegacyHandoff(with: failure.error)
            await adapter.holdNextLegacyHandoff()
            var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
            _ = try #require(await deadlines.next())
            var prompts = adapter.legacyEvents.stream.makeAsyncIterator()
            rig.clock.advance(by: .seconds(60))
            _ = try #require(await prompts.next()) // The original final authority check already admitted this handoff.
            let target = try await successor.replace(rig)
            await adapter.passLegacyHandoff()
            let fence = rig.controller.ownerState.fence
            rig.clock.advance(by: .seconds(120))
            let fresh = try #require(await prompts.next())
            let token = try lifetimePromptToken(fresh)
            await adapter.releaseLegacyHandoff() // Old captured failure returns despite task cancellation.
            try #require(await eventually { finished.count == 2 })
            try await assertLifetimeSuccessor(rig, target: target, fence: fence)
            #expect(await rig.status().outstanding)
            let report = await rig.listener.taskProgress(.init(action: .report, task: rig.task, token: token,
                                                               text: "Synthetic successor progress"))
            let update = try #require(report.update)
            #expect(report.outcome == "status" && report.task == rig.task)
            // Cut13 accepts routine info as held; cut14 delivers enrolled cards immediately.
            #expect(update.outcome == .held || update.outcome == .delivered)
            #expect(await rig.peer.session.replyRequests.isEmpty)
        }
    }

    @Test(arguments: LifetimeSuccessor.allCases)
    func delayedWakeEntryNeverFinishesAChangedEnrollment(_ successor: LifetimeSuccessor) async throws {
        let barrier = OwnerAdmissionTestBarrier()
        defer { barrier.release() }
        try await TaskProgressControllerLifetimeScope.$beforeWake.withValue(
            { await barrier.hold($0.task) }, operation: {
                try await withLifetimeWakeRig { rig, finished in
                    var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
                    _ = try #require(await deadlines.next())
                    rig.clock.advance(by: .seconds(60))
                    var entered = barrier.entered.stream.makeAsyncIterator()
                    _ = try #require(await entered.next())
                    let target = try await successor.replace(rig)
                    let fence = rig.controller.ownerState.fence
                    barrier.release()
                    try #require(await eventually { finished.count == 1 })
                    try await assertLifetimeSuccessor(rig, target: target, fence: fence)
                }
            }
        )
    }

    @Test(arguments: LifetimeWakeFailure.allCases) func currentFailureStillFinishes(_ failure: LifetimeWakeFailure)
        async throws {
        try await withLifetimeWakeRig { rig, finished in
            await rig.peer.hostRig.adapter.failLegacyHandoff(with: failure.error)
            let fence = rig.controller.ownerState.fence
            var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
            _ = try #require(await deadlines.next())
            rig.clock.advance(by: .seconds(60))
            try #require(await eventually { finished.count == 1 })
            #expect(await rig.status().task == nil)
            #expect(!fence.isOpen)
        }
    }

    @Test func currentExpiredEnrollmentStillFinishes() async throws {
        let barrier = OwnerAdmissionTestBarrier()
        defer { barrier.release() }
        try await TaskProgressControllerLifetimeScope.$beforeWake.withValue(
            { await barrier.hold($0.task) }, operation: {
                try await withLifetimeWakeRig { rig, finished in
                    var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
                    _ = try #require(await deadlines.next())
                    rig.clock.advance(by: .seconds(60))
                    var entered = barrier.entered.stream.makeAsyncIterator()
                    _ = try #require(await entered.next())
                    rig.clock.advance(by: .seconds(6 * 3_600))
                    barrier.release()
                    try #require(await eventually { finished.count == 1 })
                    #expect(await rig.status().task == nil)
                    #expect(!rig.controller.ownerState.fence.isOpen)
                }
            }
        )
    }
}
