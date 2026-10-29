import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressHandoffTests {
    enum Pause: CaseIterable, Sendable { case owner, quiet, privacy }

    @Test func adapterCancellationAfterAnAttemptKeepsOneOutstandingToken() async throws {
        let clock = ProgressTestClock(), wiring = TaskProgressHostIntegrationTests.Wiring()
        let rig = try await SessionUpdateListenerRig.make(ambient: wiring)
        wiring.owner.withLock { $0 = rig.connectionID }
        await rig.listener.enableTaskProgress(clock: clock.clock)
        await rig.hostRig.adapter.failLegacyHandoff(with: CancellationError())
        let finished = AsyncStream<Void>.makeStream()
        var completions = finished.stream.makeAsyncIterator()
        var deadlines = clock.scheduled.stream.makeAsyncIterator()
        let id = UUID()
        _ = await TaskProgressWakeScope.$didFinishWake.withValue({ finished.continuation.yield(()) }, operation: {
            await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                   task: id, seconds: 60))
        })
        _ = try #require(await deadlines.next())
        clock.advance(by: .seconds(60))
        #expect(await completions.next() != nil)
        let state = await rig.listener.taskProgress(.init(action: .status))
        #expect(state.task == id && state.outstanding && state.nextDueInSeconds == nil)
        #expect(await rig.hostRig.adapter.legacy.count == 1)
        await rig.listener.stop()
    }

    @Test(arguments: Pause.allCases) func aPauseBeforeAdapterAttemptNeverHandsOff(_ pause: Pause) async throws {
        let clock = ProgressTestClock(), wiring = TaskProgressHostIntegrationTests.Wiring()
        let rig = try await SessionUpdateListenerRig.make(ambient: wiring)
        wiring.owner.withLock { $0 = rig.connectionID }
        await rig.listener.enableTaskProgress(clock: clock.clock)
        let finished = AsyncStream<Void>.makeStream()
        var completions = finished.stream.makeAsyncIterator()
        var deadlines = clock.scheduled.stream.makeAsyncIterator()
        var listings = rig.hostRig.adapter.listingEvents.stream.makeAsyncIterator()
        let id = UUID()
        _ = await TaskProgressWakeScope.$didFinishWake.withValue({ finished.continuation.yield(()) }, operation: {
            await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                   task: id, seconds: 60))
        })
        _ = try #require(await deadlines.next())
        await rig.hostRig.adapter.holdNextListing()
        clock.advance(by: .seconds(60))
        #expect(await listings.next() != nil)
        switch pause {
        case .owner:
            _ = await rig.listener.taskProgress(.init(action: .owner, task: id, command: "pause updates"))
        case .quiet: _ = await rig.listener.sessionUpdate(.init(action: .quietOn))
        case .privacy:
            let hold = await rig.listener.replyHold
            hold.set(true, connection: rig.connectionID)
            await rig.listener.refreshTaskProgressEnvironment()
        }
        await rig.hostRig.adapter.releaseListing()
        #expect(await completions.next() != nil)
        #expect(await rig.hostRig.adapter.legacy.isEmpty)
        let state = await rig.listener.taskProgress(.init(action: .status))
        #expect(state.task == id && !state.outstanding && state.nextDueInSeconds == nil)
        await rig.listener.stop()
    }
}
