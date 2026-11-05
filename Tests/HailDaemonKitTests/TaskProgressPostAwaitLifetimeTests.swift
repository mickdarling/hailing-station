import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressPostAwaitLifetimeTests {
    @Test func oldReportCleanupCannotEraseANewerOutstandingWake() async throws {
        try await withLifetimeWakeRig { rig, finished in
            var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
            _ = try #require(await deadlines.next())
            var prompts = rig.peer.hostRig.adapter.legacyEvents.stream.makeAsyncIterator()
            rig.clock.advance(by: .seconds(60))
            let first = try #require(await prompts.next())
            let firstToken = try lifetimePromptToken(first)
            try #require(await eventually { finished.count == 1 })
            let barrier = OwnerAdmissionTestBarrier()
            defer { barrier.release() }
            let listener = rig.listener, task = rig.task
            let reporting = TaskProgressControllerLifetimeScope.$beforeReportCleanup.withValue(
                { await barrier.hold($0.task) }, operation: {
                    Task { await listener.taskProgress(.init(action: .report, task: task, token: firstToken,
                                                              text: "Synthetic first progress")) }
                }
            )
            defer { reporting.cancel() }
            var entered = barrier.entered.stream.makeAsyncIterator()
            _ = try #require(await entered.next())
            rig.clock.advance(by: .seconds(60))
            let second = try #require(await prompts.next())
            let secondToken = try lifetimePromptToken(second)
            try #require(await eventually { finished.count == 2 })
            barrier.release()
            let firstReport = await reporting.value
            let firstUpdate = try #require(firstReport.update)
            #expect(firstReport.outcome == "status")
            // Cut13 accepts routine info as held; cut14 delivers enrolled cards immediately.
            #expect(firstUpdate.outcome == .held || firstUpdate.outcome == .delivered)
            #expect(await rig.status().outstanding)
            let report = await rig.listener.taskProgress(.init(action: .report, task: task, token: secondToken,
                                                               text: "Synthetic second progress"))
            let update = try #require(report.update)
            #expect(report.outcome == "status" && report.outstanding == false)
            #expect(update.outcome == .held || update.outcome == .delivered)
            #expect(rig.controller.ownerState.fence.isOpen)
        }
    }

    @Test func listenerStopRetiresAStartHeldInItsRegistryPreflight() async throws {
        try await withTaskProgressOwnerRig { rig in
            _ = await rig.listener.taskProgress(.init(action: .cancel, task: rig.task))
            let adapter = rig.peer.hostRig.adapter
            await adapter.holdNextListing()
            let listener = rig.listener, task = rig.task
            let starting = Task { await listener.taskProgress(.init(action: .start,
                target: RecipientTestRig.target, task: task, seconds: 120)) }
            defer { starting.cancel() }
            var entered = adapter.listingEvents.stream.makeAsyncIterator()
            _ = try #require(await entered.next())
            await rig.listener.stop()
            await adapter.releaseListing()
            #expect(await starting.value.outcome == "refused")
            #expect(await rig.controller.handle(.init(action: .status)).task == nil)
            #expect(!rig.controller.ownerState.fence.isOpen)
        }
    }
}
