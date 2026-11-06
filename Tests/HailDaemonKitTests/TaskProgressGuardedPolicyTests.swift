import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressGuardedPolicyTests {
    @Test func originalPolicyRetirementStillRejectsBeforeMarkingATaskAttempt() async throws {
        let adapter = TaskProgressGuardedAdapter(), rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter)
        defer { adapter.resume() }
        let original = rig.host.targetPolicy.snapshot(for: rig.target), attempt = TaskProgressWakeAttempt()
        var arrivals = adapter.arrived.stream.makeAsyncIterator()
        let sending = Task {
            try await TaskProgressWakeScope.$beforeHandoff.withValue({ attempt.begin() }, operation: {
                try await rig.host.sendAuthorized("Synthetic status check", policyGeneration: original,
                                                 from: "synthetic-task", expectedBinding: "binding-a", context: nil)
            })
        }
        _ = try #require(await arrivals.next())
        #expect(!attempt.hasAttempt, "a registry/adapter actor hop is not an admitted handoff")
        _ = try await rig.host.deny(rig.target)
        _ = try await rig.host.allow(rig.target, tier: .open)
        adapter.resume()
        await #expect(throws: HostError.denied(.notAllowed(rig.target))) { try await sending.value }
        #expect(!attempt.hasAttempt)
        #expect(await adapter.accepted.isEmpty)
        await rig.listener.stop()
    }

    @Test func ordinaryGuardedAndUnguardedDispatchKeepTheirOriginalAuthorityRoutes() async throws {
        let adapter = AuthorityRecordingAdapter(), rig = try await DeliveryAuthorityRig.make(adapter: adapter)
        let guarded = try await rig.send("Synthetic guarded input", contextual: false)
        #expect(guarded == .delivered(["Synthetic guarded input"]))
        #expect(try await rig.host.send("Synthetic ordinary input", to: rig.context.binding.targetID)
                == .delivered(["Synthetic ordinary input"]))
        let deliveries = await adapter.deliveries
        try #require(deliveries.count == 2)
        #expect(deliveries[0].authority != nil && deliveries[1].authority == nil)
        try await adapter.requireRecordedAuthorities()
        _ = try await rig.host.deny(rig.context.binding.targetID)
        await #expect(throws: HostError.denied(.notAllowed(rig.context.binding.targetID))) {
            try await adapter.requireRecordedAuthorities()
        }
    }
}
