import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct DeliveryStageOrderTests {
    @Test func heldPredicatesPrecedePeerAndRequestClock() async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let id = try await rig.hold()
        let entry = try #require(await rig.host.heldRequests.entries[id])
        let recorder = DeliveryStageRecorder()
        let peer = try #require(rig.peer.replyTransport.issuePermit())
        var stages = await rig.session.stageOrderAuthority(peer: peer, owner: nil)
        stages.gates[.attemptCancellation] = DeliveryAdmission.Gate(validate: {}, perform: { operation in
            #expect(recorder.events.contains("router"))
            try operation()
        })
        let authority = recorder.instrument(stages).composed(
            policy: entry.policy, held: stageOrderHeldScope(entry, recorder: recorder)
        )
        try authority.admit {}
        try recorder.expectRouterBeforePeer()
        rig.peer.replyTransport.retire()
        #expect(throws: HostError.denied(.notAllowed(FinalDeliveryRig.target))) { try authority.admit {} }
        await rig.listener.stop()
    }

    @Test func sessionStagesFollowAnEarlierRouterStage() async throws {
        let rig = try await FinalDeliveryRig.make()
        let ownerID = try #require(try await rig.ambient())
        let request = try #require(await rig.session.replyRequests[ownerID])
        let peer = try #require(rig.peer.replyTransport.issuePermit())
        let owner = HostReplyOwnership(context: request.context, contextual: true)
        let outer = RetainedDeliveryStages(gates: [.taskOutputFence: .init(validate: {}, perform: { _ in
            Issue.record("session stages must start empty")
        })])
        var stages = await TaskProgressWakeScope.$retained.withValue(outer) {
            await rig.session.stageOrderAuthority(peer: peer, owner: owner)
        }
        #expect(stages.gates[.taskOutputFence] == nil)
        let recorder = DeliveryStageRecorder()
        stages.gates[.ambientRouter] = RetainedDeliveryStages.gate { operation in
            recorder.router() && operation()
        }
        let policy = await rig.host.inputPolicyGeneration(for: FinalDeliveryRig.target)
        try recorder.instrument(stages).composed(policy: policy).admit {}
        try recorder.expectRouterBeforePeer()
        let order = recorder.events.filter { $0 != "router" }
        #expect(order == ["replyPermit", "bindingLease", "ambientRouter", "peerLifecycle", "attemptCancellation"])
        await rig.listener.stop()
    }

    @Test func taskStagesAcquireRouterBeforePeer() async throws {
        let rig = try await TaskProgressGuardedWakeRig.make(adapter: TaskProgressCheckedAdapter())
        let generation = await rig.host.inputPolicyGeneration(for: rig.target)
        let task = TaskProgressTask(session: rig.target, binding: "binding-a")
        let publication = TaskProgressPublicationAuthority(generation: generation, binding: task.binding,
                                                           taskFence: TaskProgressOutputFence())
        let revision = await rig.listener.taskProgressPrivacyRevision()
        let lifetime = TaskProgressAdmissionLifetime(expires: rig.clock.now.advanced(by: .seconds(60)),
                                                     clock: rig.clock.clock)
        let stages = try #require(await rig.listener.taskProgressDeliveryStages(
            for: task, authority: publication, privacyRevision: revision,
            attempt: TaskProgressWakeAttempt(), lifetime: lifetime
        ))
        let recorder = DeliveryStageRecorder()
        var recorded = recorder.instrument(stages)
        let router = try #require(recorded.gates[.ambientRouter])
        recorded.gates[.ambientRouter] = DeliveryAdmission.Gate(validate: router.validate, perform: { operation in
            try router.perform {
                _ = recorder.router()
                try operation()
            }
        })
        try recorded.composed(policy: generation).admit {}
        try recorder.expectRouterBeforePeer()
        let order = recorder.events.filter { $0 != "router" }
        #expect(order == ["taskOutputFence", "sessionUpdateFence", "ambientRouter", "privacyHold",
                          "peerLifecycle", "attemptCancellation"])
        await rig.listener.stop()
    }

    @Test func heldRefusalsPrecedeTheRequestClock() async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let id = try await rig.hold()
        let entry = try #require(await rig.host.heldRequests.entries[id])
        let recorder = DeliveryStageRecorder()
        var stages = RetainedDeliveryStages()
        stages.gates[.attemptCancellation] = DeliveryAdmission.Gate(validate: {
            Issue.record("held predicates precede the request clock")
        }, perform: { _ in Issue.record("held predicates precede the request clock") })
        let scope = stageOrderHeldScope(entry, recorder: recorder, policyCurrent: { false })
        let authority = stages.composed(policy: entry.policy, held: scope)
        #expect(throws: HeldAuthorityError.policyChanged) { try authority.requireCurrent() }
        #expect(throws: HeldAuthorityError.policyChanged) { try authority.admit {} }
        rig.host.targetPolicy.retire(FinalDeliveryRig.target)
        #expect(throws: HeldAuthorityError.policyChanged) { try authority.admit {} }
        await rig.listener.stop()
    }

    @Test func retiredHeldGenerationKeepsItsPolicyReason() async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let id = try await rig.hold()
        let entry = try #require(await rig.host.heldRequests.entries[id])
        let scope = stageOrderHeldScope(entry, recorder: DeliveryStageRecorder())
        let authority = RetainedDeliveryStages().composed(policy: entry.policy, held: scope)
        rig.host.targetPolicy.retire(FinalDeliveryRig.target)
        HeldSendScope.$current.withValue(scope) {
            do {
                try authority.admit {}
                Issue.record("retired generations must refuse")
            } catch { scope.failure.record(error) }
        }
        #expect(scope.failure.reason == .policyChanged)
        await rig.listener.stop()
    }

}
