#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct TaskProgressPeerAdmissionTests {
    enum Retirement: CaseIterable { case peer, listener, audience, sameAudiencePeer }

    @Test(arguments: [false, true])
    func handoffRetainsOnlyItsSelectedAudiencePeer(retireAudience: Bool) async throws {
        let rig = try await TaskProgressPeerRig.make(beforeAdmission: false)
        defer { rig.release() }
        let selected = try await rig.replacePeer(sameAudience: false)
        let generation = rig.wake.host.targetPolicy.snapshot(for: rig.wake.target)
        let task = TaskProgressTask(session: rig.wake.target, binding: SlowTmuxCommandFixture.binding)
        let publication = TaskProgressPublicationAuthority(generation: generation, binding: task.binding,
                                                           taskFence: TaskProgressOutputFence())
        let attempt = TaskProgressWakeAttempt()
        let lifetime = TaskProgressAdmissionLifetime(expires: rig.wake.clock.now.advanced(by: .seconds(60)),
                                                     clock: rig.wake.clock.clock)
        let revision = await rig.wake.listener.taskProgressPrivacyRevision()
        let handoff = try #require(await rig.wake.listener.taskProgressHandoff(for: task, authority: publication,
            privacyRevision: revision, attempt: attempt, lifetime: lifetime))
        rig.peer.replyTransport.retire()
        if retireAudience {
            selected.replyTransport.retire()
            #expect(throws: CancellationError.self) { try handoff() }
            #expect(!attempt.hasAttempt)
        } else {
            try handoff()
            #expect(attempt.hasAttempt)
        }
        await rig.wake.listener.stop()
    }

    @Test(arguments: Retirement.allCases)
    func retiredPeerRefusesWakeBeforeSubmissionWhileTeardownWaits(_ retirement: Retirement) async throws {
        let rig = try await TaskProgressPeerRig.make(beforeAdmission: true)
        defer { rig.release() }
        var deadlines = rig.wake.clock.scheduled.stream.makeAsyncIterator()
        var finished = rig.wake.finished.stream.makeAsyncIterator()
        let id = try await rig.wake.start()
        _ = try #require(await deadlines.next())
        rig.wake.clock.advance(by: .seconds(60))
        try await rig.launch.waitEntered()
        #expect(rig.fixture.lines("writes").isEmpty)
        let task = TaskProgressTask(id: id, session: rig.wake.target, binding: SlowTmuxCommandFixture.binding)
        try await rig.withEndedPeer(task: task, stopping: retirement == .listener) {
            #expect(rig.peer.replyTransport.isRetired)
            #expect(rig.peer.replyTransport.issuePermit() == nil)
            if retirement == .audience || retirement == .sameAudiencePeer {
                let successor = try await rig.replacePeer(sameAudience: retirement == .sameAudiencePeer)
                let permit = try #require(successor.replyTransport.issuePermit())
                #expect(permit.performIfCurrent { true } == true)
            }
            var expectedLaunches: Int = rig.fixture.lines("launches").count
            expectedLaunches += 1 // unused buffer deletion
            rig.launch.release()
            _ = try #require(await finished.next())
            #expect(rig.fixture.lines("writes").isEmpty)
            #expect(rig.fixture.exists("deleted"))
            #expect(rig.fixture.lines("launches").count == expectedLaunches)
            let state = await rig.controller.handle(.init(action: .status))
            #expect(!state.outstanding, "refusal before admission releases only the unattempted wake")
            #expect(!rig.launch.timedOut)
        }
        await rig.wake.listener.stop()
    }

    @Test(arguments: [false, true])
    func admittedWakeCompletesAndStaysOutstandingAcrossPeerReplacement(sameAudience: Bool) async throws {
        let rig = try await TaskProgressPeerRig.make(beforeAdmission: false)
        defer { rig.release() }
        var deadlines = rig.wake.clock.scheduled.stream.makeAsyncIterator()
        var finished = rig.wake.finished.stream.makeAsyncIterator()
        let id = try await rig.wake.start()
        _ = try #require(await deadlines.next())
        rig.wake.clock.advance(by: .seconds(60))
        try await rig.files.wait("paste-started", in: rig.fixture)
        let task = TaskProgressTask(id: id, session: rig.wake.target, binding: SlowTmuxCommandFixture.binding)
        try await rig.withEndedPeer(task: task) {
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
        }
        let sleeps = rig.wake.clock.sleeps
        await rig.wake.listener.refreshTaskProgressEnvironment()
        rig.wake.clock.advance(by: .seconds(6_000))
        let later = await rig.controller.handle(.init(action: .status))
        #expect(later.task == id && later.outstanding && later.nextDueInSeconds == nil)
        #expect(rig.wake.clock.sleeps == sleeps)
        #expect(rig.fixture.lines("writes") == ["paste", "enter"])
        await rig.wake.listener.stop()
    }
}
#endif
