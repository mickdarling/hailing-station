import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct DiagnosticBridgeAuthorityTests {
    @Test func separateCliAndDaemonInstancesListSameVersionedUtilityBindingWithIndependentGates() async throws {
        let publisher = DiagnosticSyntheticPublisher()
        let first = try diagnosticBridge(publisher)
        let second = try diagnosticBridge(publisher)
        #expect(try await first.listTargets() == second.listTargets())
        let binding = try diagnosticContext().binding
        let firstLease = try await first.acquireReplyBindingLease(binding)
        let secondLease = try await second.acquireReplyBindingLease(binding)
        #expect(firstLease.binding == binding)
        #expect(secondLease.binding == binding)
        await first.stop()
        #expect(firstLease.performIfCurrent { true } == nil)
        #expect(secondLease.performIfCurrent { true } == true)
        await #expect(throws: DiagnosticBridgeError.stopped) { try await first.acquireReplyBindingLease(binding) }
        #expect(try await first.listTargets().first?.alive == false)
        await second.stop()
    }

    @Test func validatesContextAndExactBindingWithoutLegacyFallback() async throws {
        let publisher = DiagnosticSyntheticPublisher()
        let bridge = try diagnosticBridge(publisher)
        for context in [try diagnosticContext(host: "other"), try diagnosticContext(provider: "other"),
                        try diagnosticContext(target: "diagnostic-reply:other"),
                        try diagnosticContext(session: "other-binding")] {
            await #expect(throws: ProviderContractError.wrongContext) {
                try await bridge.acquireReplyBindingLease(context.binding)
            }
            await #expect(throws: ProviderContractError.wrongContext) {
                try await bridge.deliver("synthetic", to: "roundtrip",
                                         binding: diagnosticUtilityBinding, context: context)
            }
        }
        let context = try diagnosticContext()
        let envelope = try DiagnosticBridgeEnvelope.encode(requestID: UUID(), text: "synthetic")
        await #expect(throws: ProviderContractError.wrongContext) {
            try await bridge.acceptEnvelope(envelope, to: "roundtrip",
                                            binding: diagnosticUtilityBinding, context: context)
        }
        await #expect(throws: DiagnosticBridgeError.contextRequired) {
            try await bridge.deliver("synthetic", to: "roundtrip", binding: diagnosticUtilityBinding)
        }
        #expect(await bridge.diagnostics().active == 0)
        #expect(await publisher.replies.isEmpty)
        await bridge.stop()
    }

    @Test func cancelledAdmissionCannotQueueOrIssueLease() async throws {
        let publisher = DiagnosticSyntheticPublisher()
        let bridge = try diagnosticBridge(publisher)
        let context = try diagnosticContext()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                try await bridge.deliver("synthetic", to: "roundtrip",
                                         binding: diagnosticUtilityBinding, context: context)
            }
            await #expect(throws: CancellationError.self) { try await bridge.acquireReplyBindingLease(context.binding) }
        }
        await task.value
        #expect(await bridge.diagnostics().active == 0)
        #expect(await publisher.replies.isEmpty)
        await bridge.stop()
    }

    @Test func registryUsesExplicitUtilityProfileAndExactSeparatePolicyGrant() async throws {
        let publisher = DiagnosticSyntheticPublisher()
        let bridge = try diagnosticBridge(publisher)
        let registry = Registry()
        #expect(await registry.kinds.isEmpty) // No implicit registration.
        try await registry.register(bridge)
        let listed = try #require(await registry.listing().first)
        #expect(listed.info.id == DiagnosticReplyBridgeAdapter.targetID)
        #expect(listed.binding == diagnosticUtilityBinding)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore())
        let context = try diagnosticContext()
        await #expect(throws: HostError.self) {
            try await host.send("synthetic", context: context)
        }
        #expect(await publisher.replies.isEmpty)
        await bridge.stop()
    }
}
