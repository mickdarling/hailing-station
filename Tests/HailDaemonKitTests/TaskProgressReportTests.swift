import Foundation
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressReportTests {
    @Test func heldCompletionRetainsTaskAndSessionAttributionWithoutSpeakingItsMetadata() async throws {
        let rig = try await SessionUpdateListenerRig.make(send: { $0(NWError.posix(.ECONNRESET)) })
        await rig.listener.enableTaskProgress()
        let task = UUID()
        _ = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target, task: task))
        _ = await rig.listener.taskProgress(.init(action: .finish, task: task, text: "Synthetic done",
                                                  card: "Synthetic detail"))
        let held = try #require(await rig.listener.sessionUpdates.held.first)
        #expect(held.session == RecipientTestRig.target && held.spoken == "Synthetic done")
        #expect(held.card == "Task: `\(task.uuidString)`\n\nSynthetic detail")
        await rig.listener.stop()
    }

    @Test func reportReturnsTheStateAfterItsOutstandingTokenWasCompleted() async throws {
        let clock = ProgressTestClock(), wiring = TaskProgressHostIntegrationTests.Wiring()
        let rig = try await SessionUpdateListenerRig.make(ambient: wiring)
        let connection = await rig.session.connectionID
        wiring.owner.withLock { $0 = connection }
        await rig.listener.enableTaskProgress(clock: clock.clock)
        var deadlines = clock.scheduled.stream.makeAsyncIterator()
        var prompts = rig.hostRig.adapter.legacyEvents.stream.makeAsyncIterator()
        let task = UUID()
        _ = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                  task: task, seconds: 60))
        _ = try #require(await deadlines.next())
        clock.advance(by: .seconds(60))
        let prompt = try #require(await prompts.next())
        let tokenText = prompt.components(separatedBy: "--token ").last?.split(separator: " ").first
        let token = try #require(tokenText.flatMap { UUID(uuidString: String($0)) })
        let response = await rig.listener.taskProgress(.init(action: .report, task: task, token: token,
                                                             text: "Synthetic confirmed progress"))
        #expect(response.task == task && !response.outstanding && response.nextDueInSeconds == 60)
        #expect(response.update?.outcome == .delivered)
        await rig.listener.stop()
    }

    @Test func aRefusedCompletionRemainsVisibleAfterTheTaskEnds() async throws {
        let rig = try await SessionUpdateListenerRig.make()
        await rig.listener.enableTaskProgress()
        let task = UUID()
        _ = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target, task: task))
        _ = try await rig.hostRig.host.deny(RecipientTestRig.target)
        _ = try await rig.hostRig.host.allow(RecipientTestRig.target, tier: .open)
        let response = await rig.listener.taskProgress(.init(action: .finish, task: task,
                                                             text: "Synthetic completion"))
        #expect(response.task == nil && response.outcome == "refused" && response.reason == "retired_authority")
        await rig.listener.stop()
    }
}
