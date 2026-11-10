import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .frozenGuardBudget) struct AmbientHeldAdmissionTests {
    @Test(arguments: ["confirmation", "guard", "rateLimit"])
    func retiredAdmissionCannotCreateAReadBackOrHeldEntry(reason: String) async throws {
        let rig = try await HeldTestRig.make(limit: 1)
        let target = RecipientTestRig.target
        let sink = RecordingAmbientSink()
        let gate = AmbientAudioGate(target: target, sink: sink, sweepInterval: nil)
        let admitted = rig.host.targetPolicy.snapshot(for: target)
        let admission = await gate.admission(
            ambientSegment(stream: UUID(), sequence: 0), frameTarget: target,
            selection: AmbientSelection(target: target), connection: rig.session.connectionID, device: nil,
            policyGeneration: admitted, binding: "reply-binding"
        )
        try #require(admission == .admitted)
        _ = try await rig.host.deny(target)
        _ = try await rig.host.allow(target, tier: reason == "confirmation" ? .confirm : .open)
        let current = rig.host.targetPolicy.snapshot(for: target)
        #expect(!admitted.isSameGeneration(as: current))
        if reason == "rateLimit" { _ = try await rig.dispatch("first benign") }
        let baseline = await rig.adapter.contexts.count
        let text = reason == "guard" ? "HELD_TOKEN" : "second benign"
        let retained = RetainedDeliveryStages(generation: admitted)
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) {
            try await HostSession.$ambientDeliveryStages.withValue(retained) { try await rig.dispatch(text) }
        }
        #expect(await rig.host.heldRequests.entries.isEmpty)
        #expect(await rig.adapter.contexts.count == baseline)
        let hash = DeliveryRequest(target: target, binding: "reply-binding", lines: [text],
                                   device: HostSession.dispatchDevice).confirmationHash
        #expect(await !rig.host.cancel(hash))
        // The same evaluation under current authority really would hold, so each branch is exercised.
        let entry = try await rig.hold(text)
        #expect(entry.policy.isSameGeneration(as: current))
        if reason == "confirmation" { #expect(entry.reasons == [.confirmTier]) }
        if reason == "guard" { #expect(entry.reasons == [.ruleMatch]) }
        if reason == "rateLimit" { #expect(entry.reasons == [.rateLimited]) }
        // Once a legitimate held entry's own grant retires, held-send still refuses it after re-allow.
        _ = try await rig.host.deny(target)
        _ = try await rig.host.allow(target, tier: .open)
        #expect(await rig.send(entry.id) == .refused(.policyChanged))
        #expect(await rig.adapter.contexts.count == baseline)
    }
}
