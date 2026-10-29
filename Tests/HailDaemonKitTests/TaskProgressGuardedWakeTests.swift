import Foundation
import Testing
@testable import HailDaemonKit

/// Injected time and a barrier immediately before adapter authority admission. No provider/voice/I/O side effects.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressGuardedWakeTests {
    enum Retirement: CaseIterable, Sendable, Equatable {
        case pause, pauseResume, cancel, quiet, privacyPair, ambientEpoch, disconnect, media
    }

    @Test(arguments: Retirement.allCases)
    func originalTaskBoundariesSurviveUntilTheAdaptersFinalCheck(_ retirement: Retirement) async throws {
        let adapter = TaskProgressGuardedAdapter(), rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter)
        defer { adapter.resume() }
        var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
        var arrivals = adapter.arrived.stream.makeAsyncIterator()
        var finished = rig.finished.stream.makeAsyncIterator()
        let id = try await rig.start()
        let original = rig.host.targetPolicy.snapshot(for: rig.target)
        _ = try #require(await deadlines.next())
        rig.clock.advance(by: .seconds(60))
        _ = try #require(await arrivals.next())
        // Host and registry have handed off. Retirement now must still be observed by the adapter's authority.
        switch retirement {
        case .pause, .pauseResume:
            _ = await rig.listener.taskProgress(.init(action: .owner, task: id, command: "pause updates"))
            if retirement == .pauseResume {
                _ = await rig.listener.taskProgress(.init(action: .owner, task: id, command: "resume updates"))
            }
        case .cancel: _ = await rig.listener.taskProgress(.init(action: .cancel, task: id))
        case .quiet: _ = await rig.listener.sessionUpdate(.init(action: .quietOn))
        case .privacyPair:
            let hold = await rig.listener.replyHold
            hold.set(true, connection: rig.connection)
            hold.set(false, connection: rig.connection)
        case .ambientEpoch: rig.wiring.select(connection: rig.connection)
        case .disconnect: rig.wiring.disconnect()
        case .media: rig.wiring.enterMedia()
        }
        rig.clock.advance(by: .seconds(600))
        #expect(original.performIfCurrent { true } == true, "policy was never changed")
        #expect(await adapter.accepted.isEmpty)
        adapter.resume()
        _ = try #require(await finished.next())
        let checks = await adapter.checks, accepted = await adapter.accepted
        #expect(checks == 1 && accepted.isEmpty)
        let state = await rig.listener.taskProgress(.init(action: .status))
        #expect(!state.outstanding, "a refused final check proves zero side effects and releases the solicitation")
        #expect(retirement == .cancel ? state.task == nil : state.task == id)
        await rig.listener.stop()
    }

    @Test(arguments: [false, true])
    func admittedInputRetainsItsOutstandingTokenEvenWhenAdapterThenCancels(_ cancelAfter: Bool) async throws {
        let adapter = TaskProgressGuardedAdapter(), rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter)
        defer { adapter.resume() }
        if cancelAfter { await adapter.failAfterAcceptance() }
        var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
        var arrivals = adapter.arrived.stream.makeAsyncIterator()
        var finished = rig.finished.stream.makeAsyncIterator()
        let id = try await rig.start()
        _ = try #require(await deadlines.next())
        rig.clock.advance(by: .seconds(60))
        _ = try #require(await arrivals.next())
        adapter.resume()
        _ = try #require(await finished.next())
        let state = await rig.listener.taskProgress(.init(action: .status))
        #expect(state.task == id && state.outstanding && state.nextDueInSeconds == nil)
        let checks = await adapter.checks, accepted = await adapter.accepted
        #expect(checks == 1 && accepted.count == 1)
        rig.clock.advance(by: .seconds(600))
        #expect(await rig.listener.taskProgress(.init(action: .status)).outstanding)
        #expect(await adapter.accepted.count == 1, "an ambiguous accepted handoff never solicits again")
        await rig.listener.stop()
    }

    @Test func checkedHandoffAdapterKeepsItsExplicitInFlightSemantics() async throws {
        let adapter = TaskProgressCheckedAdapter(), rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter)
        defer { adapter.resume() }
        var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
        var arrivals = adapter.arrived.stream.makeAsyncIterator()
        var finished = rig.finished.stream.makeAsyncIterator()
        let id = try await rig.start()
        _ = try #require(await deadlines.next())
        rig.clock.advance(by: .seconds(60))
        _ = try #require(await arrivals.next()) // default guarded overload already checked before unguarded call
        _ = await rig.listener.taskProgress(.init(action: .owner, task: id, command: "pause updates"))
        adapter.resume()
        _ = try #require(await finished.next())
        #expect(await adapter.accepted.count == 1)
        #expect(await rig.listener.taskProgress(.init(action: .status)).outstanding)
        await rig.listener.stop()
    }
}
