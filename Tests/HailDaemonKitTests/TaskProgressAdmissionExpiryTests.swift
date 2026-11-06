import Foundation
import Testing
@testable import HailDaemonKit

/// Original enrollment time is advanced at the adapter's existing admission barrier. No sleeps or provider I/O.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressAdmissionExpiryTests {
    @Test(arguments: [0, 1])
    func originalDeadlineRefusesFirstGuardedAdmissionAndRetiresTask(_ after: Int) async throws {
        let adapter = TaskProgressGuardedAdapter(), rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter)
        defer { adapter.resume() }
        var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
        var arrivals = adapter.arrived.stream.makeAsyncIterator()
        var finished = rig.finished.stream.makeAsyncIterator()
        _ = try await rig.start()
        let original = rig.host.targetPolicy.snapshot(for: rig.target)
        _ = try #require(await deadlines.next())
        rig.clock.advance(by: .seconds(60))
        _ = try #require(await arrivals.next())
        // Nothing except time changes: no pause, policy replacement, privacy or ambient ownership transition.
        rig.clock.advance(by: .seconds(6 * 3_600 - 60 + after))
        #expect(original.performIfCurrent { true } == true)
        #expect(await adapter.accepted.isEmpty)
        adapter.resume()
        _ = try #require(await finished.next())
        let checks = await adapter.checks, accepted = await adapter.accepted
        #expect(checks == 1 && accepted.isEmpty)
        let state = await rig.listener.taskProgress(.init(action: .status))
        #expect(state.task == nil && !state.outstanding && state.nextDueInSeconds == nil)
        rig.clock.advance(by: .seconds(6 * 3_600))
        #expect(await adapter.accepted.isEmpty)
        #expect(await rig.listener.taskProgress(.init(action: .status)).nextDueInSeconds == nil)
        await rig.listener.stop()
    }

    @Test func checkedHandoffAdmittedBeforeExpiryKeepsItsExistingInFlightLimits() async throws {
        let adapter = TaskProgressCheckedAdapter(), rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter)
        defer { adapter.resume() }
        var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
        var arrivals = adapter.arrived.stream.makeAsyncIterator()
        var finished = rig.finished.stream.makeAsyncIterator()
        let id = try await rig.start()
        _ = try #require(await deadlines.next())
        rig.clock.advance(by: .seconds(60))
        _ = try #require(await arrivals.next()) // The checked handoff has already passed admission.
        rig.clock.advance(by: .seconds(6 * 3_600))
        adapter.resume()
        _ = try #require(await finished.next())
        #expect(await adapter.accepted.count == 1)
        let state = await rig.listener.taskProgress(.init(action: .status))
        #expect(state.task == id && state.outstanding && state.nextDueInSeconds == nil)
        #expect(await adapter.accepted.count == 1, "expiry does not retry or blanket-cancel admitted provider work")
        await rig.listener.stop()
    }
}
