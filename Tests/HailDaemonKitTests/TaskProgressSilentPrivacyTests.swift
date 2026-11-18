import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressSilentPrivacyTests {
    @Test(arguments: [false, true])
    func silentTaskReportMustRetainItsSolicitationPrivacyEpoch(enrolled: Bool) async throws {
        let rig = try await SilentUpdateRig.make()
        let hold = await rig.listener.replyHold
        let revision = hold.entryRevision
        let generation = rig.host.host.targetPolicy.snapshot(for: RecipientTestRig.target)
        let binding = try #require(generation.binding)
        let authority = TaskProgressPublicationAuthority(generation: generation, binding: binding,
                                                         taskFence: enrolled ? TaskProgressOutputFence() : nil)
        let result = await TaskProgressPublicationScope.$authority.withValue(authority) {
            await SessionUpdatePrivacyScope.$expectedRevision.withValue(revision) {
                await SessionUpdatePrivacyScope.$beforeAuthorityValidation.withValue({
                    hold.set(true, connection: rig.connection)
                    hold.set(false, connection: rig.connection)
                }, operation: { await rig.submit() })
            }
        }
        #expect(result.outcome == .dropped && result.reason == "private")
        #expect(rig.sends == 0, "task-report privacy epochs must remain unchanged without a renderer")
        await rig.listener.stop()
    }

    @Test func ordinaryInfoStillDeliversAcrossPrivacyPairDuringSubmission() async throws {
        let rig = try await SilentUpdateRig.make()
        let hold = await rig.listener.replyHold
        let result = await SessionUpdatePrivacyScope.$beforeAuthorityValidation.withValue({
            hold.set(true, connection: rig.connection)
            hold.set(false, connection: rig.connection)
        }, operation: { await rig.submit() })
        #expect(result.outcome == .delivered && rig.sends == 1)
        await rig.listener.stop()
    }

    @Test func configuringSpeechDuringSubmissionKeepsPrivacyRejectionAndBudget() async throws {
        let rig = try await SilentUpdateRig.make()
        let queue = await rig.listener.sessionUpdates
        let hold = await rig.listener.replyHold
        let result = await SessionUpdatePrivacyScope.$beforeAuthorityValidation.withValue({
            await rig.listener.configureSessionUpdateSpeech(UnusedUpdateSpeech())
            hold.set(true, connection: rig.connection)
            hold.set(false, connection: rig.connection)
        }, operation: { await rig.submit() })
        #expect(result.outcome == .dropped && result.reason == "private" && rig.sends == 0)
        #expect(await rig.listener.sessionUpdates == queue, "privacy rejection must not spend submission budget")
        await rig.listener.stop()
    }

    @Test func enrolledSilentReportMustNotCrossPrivacyPairDuringSubmission() async throws {
        let clock = ProgressTestClock(), wiring = SilentTaskProgressWiring()
        let rig = try await SilentUpdateRig.make(ambient: wiring)
        wiring.owner.withLock { $0 = rig.connection }
        await rig.listener.enableTaskProgress(clock: clock.clock)
        var deadlines = clock.scheduled.stream.makeAsyncIterator()
        var prompts = rig.host.adapter.legacyEvents.stream.makeAsyncIterator()
        let task = UUID()
        _ = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                  task: task, seconds: 60))
        _ = try #require(await deadlines.next())
        clock.advance(by: .seconds(60))
        let prompt = try #require(await prompts.next())
        let tokenText = prompt.components(separatedBy: "--token ").last?.split(separator: " ").first
        let token = try #require(tokenText.flatMap { UUID(uuidString: String($0)) })
        let hold = await rig.listener.replyHold
        let response = await SessionUpdatePrivacyScope.$beforeAuthorityValidation.withValue({
            hold.set(true, connection: rig.connection)
            hold.set(false, connection: rig.connection)
        }, operation: {
            await rig.listener.taskProgress(.init(action: .report, task: task, token: token,
                                                  text: "Synthetic stale enrolled progress"))
        })
        #expect(response.update?.outcome == .dropped && response.update?.reason == "private")
        #expect(rig.sends == 0)
        await rig.listener.stop()
    }

    @Test(arguments: [false, true])
    func taskInfoKeepsMainSubmissionAndHeldPrivacyRules(enrolled: Bool) async throws {
        let rig = try await SilentUpdateRig.make()
        let generation = rig.host.host.targetPolicy.snapshot(for: RecipientTestRig.target)
        let authority = TaskProgressPublicationAuthority(generation: generation,
            binding: try #require(generation.binding),
            taskFence: enrolled ? TaskProgressOutputFence() : nil)
        let report = await TaskProgressPublicationScope.$authority.withValue(authority) { await rig.submit() }
        #expect(report.outcome == (enrolled ? .delivered : .held))
        #expect(rig.sends == (enrolled ? 1 : 0))
        let hold = await rig.listener.replyHold
        hold.set(true, connection: rig.connection)
        hold.set(false, connection: rig.connection)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        await rig.listener.drainSessionUpdates(.interaction)
        #expect(rig.sends == (enrolled ? 1 : 0))
        await rig.listener.stop()
    }

    @Test func taskPrivacyAtFinalEnqueueStillRefusesWithoutRenderer() async throws {
        let rig = try await SilentUpdateRig.make()
        let generation = rig.host.host.targetPolicy.snapshot(for: RecipientTestRig.target)
        let authority = TaskProgressPublicationAuthority(generation: generation,
            binding: try #require(generation.binding),
            taskFence: TaskProgressOutputFence())
        let hold = await rig.listener.replyHold
        let report = await TaskProgressPublicationScope.$authority.withValue(authority) {
            await SessionUpdatePrivacyScope.$beforeEnqueue.withValue({
                hold.set(true, connection: rig.connection)
                hold.set(false, connection: rig.connection)
            }, operation: { await rig.submit() })
        }
        #expect(report.outcome == .dropped && report.reason == "private" && rig.sends == 0)
        await rig.listener.stop()
    }
}

/// Same enrolled-controller path as a spoken host, with a silent audience hook to expose accidental exemptions.
private final class SilentTaskProgressWiring: AmbientListenerWiring {
    let owner = Mutex<UUID?>(nil)
    let stream = UUID()
    func attach(_ listener: WebSocketListener) {}
    func stop(connection: UUID) {}
    func shutdown() async {}
    func deviceVoiceStopped(connection: UUID, latencyMs: Int?) async {}
    func isLatest(stream: UUID, connection: UUID) -> Bool { owner.withLock { $0 == connection } }
    func activeConnection() -> UUID? { owner.withLock { $0 } }
    var sessionUpdatesPrivate: Bool { false }
    func withSessionUpdatePermission(connection: UUID, enqueue: @Sendable () -> Bool) -> Bool { enqueue() }
    func withSilentSessionUpdateAudience(_ enqueue: @Sendable (UUID?) -> Bool) -> Bool {
        owner.withLock { enqueue($0) }
    }
    func taskProgressAudience() -> TaskProgressAmbientAudience? {
        owner.withLock { $0.map { TaskProgressAmbientAudience(connection: $0, stream: stream) } }
    }
    func withTaskProgressPermission(
        _ audience: TaskProgressAmbientAudience, commit: @Sendable () -> Bool
    ) -> Bool {
        owner.withLock { $0 == audience.connection && stream == audience.stream && commit() }
    }
}
