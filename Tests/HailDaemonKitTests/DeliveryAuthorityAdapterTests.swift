import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct DeliveryAuthorityAdapterTests {
    @Test(arguments: [false, true])
    func everyGuardedLineReceivesRetainedAuthority(_ contextual: Bool) async throws {
        let adapter = AuthorityRecordingAdapter()
        let rig = try await DeliveryAuthorityRig.make(adapter: adapter)
        #expect(try await rig.send("one\ntwo\nthree", contextual: contextual) == .delivered(["one", "two", "three"]))
        let deliveries: [AuthorityRecordingAdapter.Delivery] = await adapter.deliveries
        #expect(deliveries.map(\.text) == ["one", "two", "three"])
        #expect(deliveries.allSatisfy { $0.target == "a" && $0.binding == "binding-a" && $0.authority != nil })
        #expect(deliveries.allSatisfy { $0.context == (contextual ? rig.context : nil) })
        try await adapter.requireRecordedAuthorities()
        _ = try await rig.host.setTier(.open, for: rig.context.binding.targetID)
        let expected: HostError = .denied(.notAllowed(rig.context.binding.targetID))
        // Every retained line must remain retired even though the replacement grant is identical.
        for delivery in deliveries {
            let authority: DeliveryAuthority = try #require(delivery.authority)
            #expect(throws: expected) { try authority.requireCurrent() }
        }
        await #expect(throws: expected) { try await adapter.requireRecordedAuthorities() }
    }

    @Test(arguments: [false, true])
    func unsupportedGuardedDeliveryNeverFallsBack(_ contextual: Bool) async throws {
        let adapter = SyntheticContextAdapter()
        await adapter.setTargets([AdapterTarget(name: "a", binding: "binding-a")])
        let rig = try await DeliveryAuthorityRig.make(adapter: adapter)
        await #expect(throws: AdapterError.deliveryFailed("guarded_delivery_unsupported")) {
            try await rig.send("one", contextual: contextual)
        }
        #expect(await adapter.legacy.isEmpty)
        #expect(await adapter.contextual.isEmpty)
    }

    @Test(arguments: [false, true])
    func unguardedDeliveryKeepsExistingRoutes(_ contextual: Bool) async throws {
        let adapter = AuthorityRecordingAdapter()
        let rig = try await DeliveryAuthorityRig.make(adapter: adapter)
        let result: SendOutcome = contextual
            ? try await rig.host.send("one\ntwo", context: rig.context)
            : try await rig.host.send("one\ntwo", to: rig.context.binding.targetID)
        #expect(result == .delivered(["one", "two"]))
        let deliveries: [AuthorityRecordingAdapter.Delivery] = await adapter.deliveries
        #expect(deliveries.map(\.text) == ["one", "two"])
        #expect(deliveries.allSatisfy { $0.authority == nil && $0.context == (contextual ? rig.context : nil) })
    }

    @Test func retirementReachesAdapterWhilePolicyWriteIsBlocked() async throws {
        let blocked = PolicyWriteGate()
        defer { blocked.fire() }
        let adapter = AuthorityRecordingAdapter()
        let rig = try await DeliveryAuthorityRig.make(adapter: adapter, beforeUpdate: { blocked.suspend() })
        _ = try await rig.send("one", contextual: true)
        let writing = Task(executorPreference: blocked.executor) {
            try await rig.host.deny(rig.context.binding.targetID)
        }
        try await blocked.waitUntilSuspended()
        let expected: HostError = .denied(.notAllowed(rig.context.binding.targetID))
        _ = try await selectionPreflightStep("adapter authority check during policy write") {
            await #expect(throws: expected) { try await adapter.requireRecordedAuthorities() }
        }
        #expect(try await blocked.finish(writing))
    }

    @Test(arguments: [false, true])
    func adapterWithoutGuardedSupportKeepsUnguardedDelivery(_ contextual: Bool) async throws {
        let adapter = SyntheticContextAdapter()
        await adapter.setTargets([AdapterTarget(name: "a", binding: "binding-a")])
        let rig = try await DeliveryAuthorityRig.make(adapter: adapter)
        let result: SendOutcome = contextual
            ? try await rig.host.send("one", context: rig.context)
            : try await rig.host.send("one", to: rig.context.binding.targetID)
        #expect(result == .delivered(["one"]))
        #expect(await adapter.legacy == (contextual ? [] : ["one"]))
        #expect(await adapter.contextual.map(\.text) == (contextual ? ["one"] : []))
    }

    @Test func adapterAuthorityCheckDoesNoPolicyRead() async throws {
        let adapter = AuthorityRecordingAdapter()
        let rig = try await DeliveryAuthorityRig.make(adapter: adapter)
        _ = try await rig.send("one", contextual: false)
        let loads: Int = rig.store.loads
        rig.store.setLoadError(PolicyFileError.unwritable("synthetic"))
        try await adapter.requireRecordedAuthorities()
        #expect(rig.store.loads == loads)
        // A host refresh observes the failure and retires the token; the adapter does no reload itself.
        let refreshed: Policy? = await rig.host.refreshedPolicy()
        #expect(refreshed == nil)
        await #expect(throws: HostError.denied(.notAllowed(rig.context.binding.targetID))) {
            try await adapter.requireRecordedAuthorities()
        }
        #expect(rig.store.loads == loads + 1)
    }
}

extension DeliveryAuthorityAdapterTests {
    @Test func diagnosticRefusesRetiredAuthorityBeforeQueueAdmission() async throws {
        let publisher = DiagnosticSyntheticPublisher()
        let adapter = try diagnosticBridge(publisher)
        let registry = Registry()
        try await registry.register(adapter)
        let target = DiagnosticReplyBridgeAdapter.targetID
        let context = try diagnosticContext()
        var policy = Policy()
        try policy.allow(target, binding: diagnosticUtilityBinding, tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let retained = host.targetPolicy.snapshot(for: target).deliveryAuthority
        #expect(try await host.deny(target))
        _ = try await host.allow(target, tier: .open)
        await #expect(throws: HostError.denied(.notAllowed(target))) {
            try await registry.deliver("one", to: target, binding: diagnosticUtilityBinding,
                                       context: context, authority: retained)
        }
        let status = await adapter.diagnostics()
        #expect(status.queued == 0 && status.active == 0 && status.completed == 0)
        #expect(await publisher.replies.isEmpty)
        // The same request with fresh authority must still be admissible: no stale queue entry or tombstone.
        try await registry.deliver("one", to: target, binding: diagnosticUtilityBinding, context: context,
                                   authority: host.targetPolicy.snapshot(for: target).deliveryAuthority)
        await publisher.waitForCount(1)
        let reply = try #require(await publisher.replies.first)
        #expect(reply.requestID == context.id && reply.sequence == 1)
        await publisher.complete(reply.requestID)
        try await diagnosticWait { await adapter.diagnostics().completed == 1 }
        await adapter.stop()
    }
}

#if os(macOS)
extension DeliveryAuthorityAdapterTests {
    @Test func codexRefusesRetiredAuthorityBeforeProviderTurnHandoff() async throws {
        _ = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(), verifiedVersion: "0.159.0"
        ) { adapter in
            let registry = Registry()
            try await registry.register(adapter)
            let target = CodexAppServerFixtures.target
            var policy = Policy()
            try policy.allow(target, binding: adapter.sessionID, tier: .open)
            let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
            let binding = try ProviderSessionBinding(hostID: "synthetic-host", providerID: adapter.kind,
                                                     targetID: target, sessionID: adapter.sessionID)
            let context = CodexAppServerFixtures.context(binding)
            let observation = try await adapter.observe(binding)
            defer { observation.cancel() }
            let retained = host.targetPolicy.snapshot(for: target).deliveryAuthority
            _ = try await host.setTier(.open, for: target)
            await #expect(throws: HostError.denied(.notAllowed(target))) {
                try await registry.deliver("one", to: target, binding: adapter.sessionID,
                                           context: context, authority: retained)
            }
            #expect(await adapter.bufferedEarlyRecords == 0)
            // Fresh delivery of the same context proves the refused call never reserved or wrote a provider turn.
            try await registry.deliver("one", to: target, binding: adapter.sessionID, context: context,
                                       authority: host.targetPolicy.snapshot(for: target).deliveryAuthority)
            var events = observation.events.makeAsyncIterator()
            let accepted = try #require(try await events.next())
            #expect(accepted.turn == context && accepted.sequence == 0 && accepted.kind == .accepted)
        }
    }
}
#endif
