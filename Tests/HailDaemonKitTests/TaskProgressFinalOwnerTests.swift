import Foundation
import Testing
@testable import HailDaemonKit

/// Retain the exact commit closure across a real router ownership edge. Lifecycle refresh is not needed to refuse it.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressFinalOwnerTests {
    enum Edge: CaseIterable, Sendable { case end, replaceSameConnection, takeOver, expired }

    @Test(arguments: Edge.allCases) func retainedInputCommitCannotOutliveItsAmbientOwner(_ edge: Edge) async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let router = AmbientRightyoRouter(configuration: .init(executable: fake.executable, config: fake.config,
            target: RecipientTestRig.target, binding: "reply-binding", allowSynthetic: true,
            timing: .init(eofGrace: 20, termGrace: 20), replyControl: false))
        let rig = try await SessionUpdateListenerRig.make(ambient: router)
        let first = UUID(), selection = await rig.session.selectionGeneration
        router.ambientAudio(.started(stream: first, connection: rig.connectionID, selection: selection))
        await router.taskProgressChanges.queued({}).value
        let generation = await rig.hostRig.host.inputPolicyGeneration(for: RecipientTestRig.target)
        let authority = TaskProgressPublicationAuthority(generation: generation, binding: "reply-binding",
                                                          taskFence: TaskProgressOutputFence())
        let attempt = TaskProgressWakeAttempt()
        let task = TaskProgressTask(session: RecipientTestRig.target, binding: "reply-binding")
        let revision = await rig.listener.taskProgressPrivacyRevision()
        let clock = ProgressTestClock()
        let lifetime = TaskProgressAdmissionLifetime(expires: clock.now.advanced(by: .seconds(6 * 3_600)),
                                                       clock: clock.clock)
        let commit = try #require(await rig.listener.taskProgressHandoff(for: task, authority: authority,
            privacyRevision: revision, attempt: attempt, lifetime: lifetime))
        switch edge {
        case .end: router.ambientAudio(.ended(stream: first, reason: .final))
        case .replaceSameConnection:
            router.ambientAudio(.started(stream: UUID(), connection: rig.connectionID, selection: selection))
        case .takeOver: router.ambientAudio(.started(stream: UUID(), connection: UUID(), selection: nil))
        case .expired: clock.advance(by: .seconds(6 * 3_600))
        }
        #expect(throws: CancellationError.self) { try commit() }
        #expect(!attempt.hasAttempt)
        await rig.listener.stop()
    }
}
