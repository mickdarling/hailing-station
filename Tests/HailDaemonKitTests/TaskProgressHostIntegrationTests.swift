import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Entirely synthetic clock, registry and transport; no provider, device or live speech is contacted.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressHostIntegrationTests {
    final class Wiring: AmbientListenerWiring {
        let owner = Mutex<UUID?>(nil)
        let stream = UUID()
        func attach(_ listener: WebSocketListener) {}
        func stop(connection: UUID) {}
        func shutdown() async {}
        func isLatest(stream: UUID, connection: UUID) -> Bool { owner.withLock { $0 == connection } }
        func activeConnection() -> UUID? { owner.withLock { $0 } }
        var sessionUpdatesPrivate: Bool { false }
        func withSessionUpdatePermission(connection: UUID, enqueue: @Sendable () -> Bool) -> Bool { enqueue() }
        func taskProgressAudience() -> TaskProgressAmbientAudience? {
            owner.withLock { $0.map { TaskProgressAmbientAudience(connection: $0, stream: stream) } }
        }
        func withTaskProgressPermission(
            _ audience: TaskProgressAmbientAudience, commit: @Sendable () -> Bool
        ) -> Bool {
            owner.withLock { $0 == audience.connection && stream == audience.stream && commit() }
        }
    }

    @Test func enrollmentControlsAndCancelUseOneInspectableState() async throws {
        let rig = try await SessionUpdateListenerRig.make()
        let task = UUID()
        #expect(await rig.listener.taskProgress(.init(action: .status)).outcome == "not_enabled")
        await rig.listener.enableTaskProgress()
        let started = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                           task: task, seconds: 60))
        #expect(started.task == task && started.pauseReason == "notListening")
        #expect(started.nextDueInSeconds == nil && started.outstanding == false)
        let owner = await rig.listener.taskProgress(.init(action: .owner, task: task,
                                                         command: "progress updates every 2 minutes"))
        #expect(owner.intervalSeconds == 120 && owner.setBy == "owner")
        let agent = await rig.listener.taskProgress(.init(action: .interval, task: task, seconds: 30))
        #expect(agent.outcome == "refused" && agent.intervalSeconds == 120)
        let replacement = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                               task: UUID(), seconds: 30))
        #expect(replacement.reason == "task_already_active")
        let canceled = await rig.listener.taskProgress(.init(action: .cancel, task: task))
        #expect(canceled.task == nil && canceled.outstanding == false)
        await rig.listener.stop()
    }

    @Test func deadlinePromptsNeverAcquireReplyOwnershipAndPrivacyInvalidatesTheirReports() async throws {
        let clock = ProgressTestClock(), wiring = Wiring()
        let rig = try await SessionUpdateListenerRig.make(ambient: wiring)
        wiring.owner.withLock { $0 = rig.connectionID }
        await rig.listener.enableTaskProgress(clock: clock.clock)
        var due = clock.scheduled.stream.makeAsyncIterator()
        var prompts = rig.hostRig.adapter.legacyEvents.stream.makeAsyncIterator()
        let task = UUID()
        let started = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                           task: task, seconds: 60))
        #expect(started.nextDueInSeconds == 60)
        _ = try #require(await due.next())
        clock.advance(by: .seconds(60))
        let prompt = try #require(await prompts.next())
        #expect(prompt.contains(task.uuidString) && !prompt.contains("--request"))
        #expect(await rig.hostRig.adapter.contexts.isEmpty)
        #expect(await rig.session.replyRequests.isEmpty)
        let pieces = prompt.components(separatedBy: "--token ")
        let token = try #require(pieces.last?.split(separator: " ").first.flatMap { UUID(uuidString: String($0)) })
        let hold = await rig.listener.replyHold
        hold.set(true, connection: rig.connectionID)
        hold.set(false, connection: rig.connectionID)
        let report = await rig.listener.taskProgress(.init(action: .report, task: task, token: token,
                                                          text: "Synthetic old progress"))
        #expect(report.outcome == "suppressed")
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        #expect(await rig.listener.taskProgress(.init(action: .status)).outstanding == false)
        let stale = await rig.listener.taskProgress(.init(action: .report, task: task, token: token))
        #expect(stale.reason == "stale_update")
        await rig.listener.stop()
    }

    @Test func socketSchemaRejectsRequestAuthorityAndIrrelevantFields() throws {
        let invalid = Data(#"{"kind":"task_progress","action":"status","request":"stale"}"#.utf8)
        #expect(throws: (any Error).self) { try LocalTaskProgressRequest.decode(invalid) }
        let owner = Data(#"{"kind":"task_progress","action":"owner","command":"pause updates","seconds":30}"#.utf8)
        #expect(throws: (any Error).self) { try LocalTaskProgressRequest.decode(owner) }
        let status = LocalTaskProgressRequest(action: .status)
        #expect(try LocalTaskProgressRequest.decode(JSONEncoder().encode(status)) == status)
    }

    @Test func retainedTaskPublicationCannotSurvivePolicyRevokeAndRestore() async throws {
        let calls = Mutex(0)
        let rig = try await SessionUpdateListenerRig.make(send: { completion in
            calls.withLock { $0 += 1 }
            completion(nil)
        })
        let generation = await rig.hostRig.host.inputPolicyGeneration(for: RecipientTestRig.target)
        let authority = TaskProgressPublicationAuthority(generation: generation, binding: "reply-binding")
        let held = await TaskProgressPublicationScope.$authority.withValue(authority) {
            await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                   text: "Synthetic retained progress"))
        }
        #expect(held.held == 1)
        _ = try await rig.hostRig.host.deny(RecipientTestRig.target)
        _ = try await rig.hostRig.host.allow(RecipientTestRig.target, tier: .open)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(calls.withLock { $0 } == 0)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        await rig.listener.stop()
    }

    @Test func aPreparedTaskPublicationKeepsItsOriginalAuthorityAtFinalEnqueue() async throws {
        let rig = try await SessionUpdateListenerRig.make()
        let generation = await rig.hostRig.host.inputPolicyGeneration(for: RecipientTestRig.target)
        let authority = TaskProgressPublicationAuthority(generation: generation, binding: "reply-binding")
        let update = try #require(SessionUpdate(session: RecipientTestRig.target, priority: .action,
                                                spoken: "Synthetic task completion", submitted: .now))
        let admission = try #require(await rig.session.prepareSessionUpdate(update, lastInput: nil,
                                                                            taskAuthority: authority))
        _ = try await rig.hostRig.host.deny(RecipientTestRig.target)
        _ = try await rig.hostRig.host.allow(RecipientTestRig.target, tier: .open)
        let called = Mutex(false)
        #expect(await !rig.session.enqueueSessionUpdate(admission, lastInput: nil, enqueue: {
            called.withLock { $0 = true }
            return true
        }))
        #expect(!called.withLock { $0 })
        await rig.listener.stop()
    }

    @Test func enrolledCadenceShowsItsCardWithoutWaitingForAnotherOwnerRequest() async throws {
        let rig = try await SessionUpdateListenerRig.make()
        let generation = await rig.hostRig.host.inputPolicyGeneration(for: RecipientTestRig.target)
        let authority = TaskProgressPublicationAuthority(generation: generation, binding: "reply-binding",
                                                          taskFence: TaskProgressOutputFence())
        let delivered = await TaskProgressPublicationScope.$authority.withValue(authority) {
            await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                   text: "Synthetic enrolled progress"))
        }
        #expect(delivered.outcome == .delivered && delivered.held == 0)
        await rig.listener.stop()
    }

    @Test func ownerCanStopAndResumeCadenceWhileQuietKeepsOutputPaused() async throws {
        let wiring = Wiring(), rig = try await SessionUpdateListenerRig.make(ambient: wiring)
        wiring.owner.withLock { $0 = rig.connectionID }
        await rig.listener.enableTaskProgress()
        let task = UUID(), stream = UUID()
        _ = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                  task: task, seconds: 60))
        _ = await rig.listener.sessionUpdate(.init(action: .quietOn))
        #expect(await rig.listener.taskProgressOwner(.stop, connection: rig.connectionID, stream: stream))
        #expect(await rig.listener.taskProgress(.init(action: .status)).pauseReason == "ownerStopped")
        #expect(await rig.listener.taskProgressOwner(.resume, connection: rig.connectionID, stream: stream))
        #expect(await rig.listener.taskProgress(.init(action: .status)).pauseReason == "quiet")
        await rig.listener.stop()
    }
}
