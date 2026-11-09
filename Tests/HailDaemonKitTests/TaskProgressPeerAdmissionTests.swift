#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct TaskProgressPeerAdmissionTests {
    enum Retirement: CaseIterable { case peer, listener, audience, sameAudiencePeer }

    @Test(arguments: Retirement.allCases)
    func retiredPeerRefusesWakeBeforeSubmissionWhileTeardownWaits(_ retirement: Retirement) async throws {
        let rig = try await TaskProgressPeerRig.make(beforeAdmission: true)
        defer { rig.release() }
        var deadlines = rig.wake.clock.scheduled.stream.makeAsyncIterator()
        var finished = rig.wake.finished.stream.makeAsyncIterator()
        var teardown = rig.teardown.entered.stream.makeAsyncIterator()
        let id = try await rig.wake.start()
        _ = try #require(await deadlines.next())
        rig.wake.clock.advance(by: .seconds(60))
        try await rig.launch.waitEntered()
        #expect(rig.fixture.lines("writes").isEmpty)
        let task = TaskProgressTask(id: id, session: rig.wake.target, binding: SlowTmuxCommandFixture.binding)
        let ending = rig.endPeer(task: task, stopping: retirement == .listener)
        _ = try #require(await teardown.next())
        #expect(rig.peer.replyTransport.isRetired)
        #expect(rig.peer.replyTransport.issuePermit() == nil)
        if retirement == .audience || retirement == .sameAudiencePeer {
            let successor = try await rig.replacePeer(sameAudience: retirement == .sameAudiencePeer)
            let permit = try #require(successor.replyTransport.issuePermit())
            #expect(permit.performIfCurrent { true } == true)
        }
        rig.launch.release()
        _ = try #require(await finished.next())
        #expect(rig.fixture.lines("writes").isEmpty)
        #expect(rig.fixture.exists("deleted"))
        let state = await rig.controller.handle(.init(action: .status))
        #expect(!state.outstanding, "refusal before admission releases only the unattempted wake")
        #expect(!rig.launch.timedOut)
        rig.teardown.release()
        await ending.value
        await rig.wake.listener.stop()
    }

    @Test(arguments: [false, true])
    func admittedWakeCompletesAndStaysOutstandingAcrossPeerReplacement(sameAudience: Bool) async throws {
        let rig = try await TaskProgressPeerRig.make(beforeAdmission: false)
        defer { rig.release() }
        var deadlines = rig.wake.clock.scheduled.stream.makeAsyncIterator()
        var finished = rig.wake.finished.stream.makeAsyncIterator()
        var teardown = rig.teardown.entered.stream.makeAsyncIterator()
        let id = try await rig.wake.start()
        _ = try #require(await deadlines.next())
        rig.wake.clock.advance(by: .seconds(60))
        try await rig.files.wait("paste-started", in: rig.fixture)
        let task = TaskProgressTask(id: id, session: rig.wake.target, binding: SlowTmuxCommandFixture.binding)
        let ending = rig.endPeer(task: task)
        _ = try #require(await teardown.next())
        #expect(rig.peer.replyTransport.isRetired)
        #expect(!rig.fixture.exists("paste-finished"))
        #expect(!rig.fixture.exists("entered"))
        _ = try await rig.replacePeer(sameAudience: sameAudience)
        rig.fixture.release()
        _ = try #require(await finished.next())
        #expect(rig.fixture.lines("writes") == ["paste", "enter"])
        #expect(!rig.fixture.exists("timed-out"))
        let state = await rig.controller.handle(.init(action: .status))
        #expect(state.task == id && state.outstanding && state.nextDueInSeconds == nil)
        rig.teardown.release()
        await ending.value
        await rig.wake.listener.refreshTaskProgressEnvironment()
        rig.wake.clock.advance(by: .seconds(6_000))
        let later = await rig.controller.handle(.init(action: .status))
        #expect(later.task == id && later.outstanding && later.nextDueInSeconds == nil)
        #expect(rig.wake.clock.sleeps == 1)
        #expect(rig.fixture.lines("writes") == ["paste", "enter"])
        await rig.wake.listener.stop()
    }
}
#endif
