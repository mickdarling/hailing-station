import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct DeliveryAdmissionCompositionTests {
    enum Retirement: CaseIterable { case policy, permit, lease, peer, lifetime, backwardsClock }

    @Test(arguments: Retirement.allCases)
    func retainedStagesRefuseIndependentRetirement(_ retirement: Retirement) throws {
        let rig = try CompositionRig()
        let authority = rig.retained.composed(policy: rig.generation)
        #expect(authority.supportsAdmission)
        try authority.requireCurrent()
        #expect(!rig.attempt.hasAttempt)
        switch retirement {
        case .policy: rig.policy.retire(CompositionRig.target)
        case .permit: rig.reply.invalidate()
        case .lease: rig.binding.invalidate()
        case .peer: rig.peer.retire()
        case .lifetime: rig.clock.advance(120_000)
        case .backwardsClock: rig.clock.advance(-1)
        }
        let operations = Mutex(0)
        #expect(throws: (any Error).self) {
            try authority.admit { operations.withLock { $0 += 1 } }
        }
        #expect(operations.withLock { $0 } == 0)
        #expect(!rig.attempt.hasAttempt)
    }

    @Test func retainedStagesSurviveTaskLocalReplacement() throws {
        let original = try CompositionRig(), replacement = try CompositionRig()
        let authority = TaskProgressWakeScope.$retained.withValue(original.retained) {
            original.retained.composed(policy: original.generation)
        }
        try TaskProgressWakeScope.$retained.withValue(replacement.retained) {
            try authority.admit {}
        }
        #expect(original.attempt.hasAttempt)
        #expect(!replacement.attempt.hasAttempt)
        original.peer.retire()
        TaskProgressWakeScope.$retained.withValue(replacement.retained) {
            #expect(throws: CancellationError.self) { try authority.admit {} }
        }
    }

    @Test func taskContributionUsesTheHostsSinglePolicyGate() async throws {
        let adapter = TaskProgressCheckedAdapter()
        let rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter)
        let generation = await rig.host.inputPolicyGeneration(for: rig.target)
        let task = TaskProgressTask(session: rig.target, binding: "binding-a")
        let attempt = TaskProgressWakeAttempt()
        let lifetime = TaskProgressAdmissionLifetime(expires: rig.clock.now.advanced(by: .seconds(60)),
                                                     clock: rig.clock.clock)
        let publication = TaskProgressPublicationAuthority(generation: generation, binding: task.binding,
                                                           taskFence: TaskProgressOutputFence())
        let revision = await rig.listener.taskProgressPrivacyRevision()
        let retained = try #require(await rig.listener.taskProgressDeliveryStages(
            for: task, authority: publication, privacyRevision: revision, attempt: attempt, lifetime: lifetime
        ))
        #expect(retained.gates[.targetPolicy] == nil)
        let authority = retained.composed(policy: generation)
        try authority.requireCurrent()
        #expect(!attempt.hasAttempt)
        // The real policy lock encloses the real task fence. Re-entry cannot complete this operation.
        let result: Int = try authority.admit { 42 }
        #expect(result == 42)
        #expect(attempt.hasAttempt)
        await rig.listener.stop()
    }

    @Test func aDifferentRetainedGenerationCannotCompose() throws {
        let original = try CompositionRig(), replacement = try CompositionRig()
        let authority = original.retained.composed(policy: replacement.generation)
        #expect(throws: HostError.denied(.notAllowed(CompositionRig.target))) { try authority.admit {} }
        #expect(!original.attempt.hasAttempt)
    }
}

private struct CompositionRig {
    static let target = "synthetic:target"
    let policy: TargetPolicyAuthority
    let generation: TargetPolicyGeneration
    let reply = ReplyPublicationAuthority()
    let binding = ReplyPublicationAuthority()
    let peer = ReplyTransportLifecycle()
    let clock = RecipientTestClock()
    let attempt = TaskProgressWakeAttempt()
    let retained: RetainedDeliveryStages

    init() throws {
        var configuration = Policy()
        try configuration.allow(Self.target, binding: "synthetic-binding", tier: .open)
        policy = TargetPolicyAuthority(store: InMemoryPolicyStore(configuration))
        policy.update(configuration)
        generation = policy.snapshot(for: Self.target)
        let permit = reply.issuePermit(), lease = binding.issuePermit()
        let transport = try #require(peer.issuePermit())
        let created = clock.instant(), clock = self.clock, attempt = self.attempt
        let current: @Sendable () throws -> Void = {
            let elapsed = created.duration(to: clock.instant())
            guard elapsed >= .zero && elapsed < HostReplyRequest.lifetime else { throw CancellationError() }
        }
        var stages = RetainedDeliveryStages(generation: generation)
        stages.gates[.replyPermit] = RetainedDeliveryStages.gate { permit.performIfCurrent($0) == true }
        stages.gates[.bindingLease] = RetainedDeliveryStages.gate { lease.performIfCurrent($0) == true }
        stages.gates[.peerLifecycle] = RetainedDeliveryStages.gate { transport.performIfCurrent($0) == true }
        stages.gates[.attemptCancellation] = DeliveryAdmission.Gate(validate: current, perform: { operation in
            try current()
            attempt.begin()
            try operation()
        })
        retained = stages
    }
}
