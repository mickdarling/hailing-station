import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderContextDispatchTests {
    @Test func contextUsesTheExactGuardedLiteralDelivery() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        #expect(try await rig.host.send("\u{1B}[31msynthetic input\u{1B}[0m", context: rig.context) ==
            .delivered(["synthetic input"]))
        #expect(await adapter.contextual == [.init(text: "synthetic input", target: "session",
                                                  binding: "binding-test", context: rig.context)])
        #expect(await adapter.legacy.isEmpty)
    }

    @Test func unsupportedModeRefusesBeforeWritingAndConsumingConfirmation() async throws {
        let adapter = FakeAdapter(kind: "test", targets: [ProviderContextTestRig.target])
        let rig = try await ProviderContextTestRig.make(adapter: adapter, tier: .confirm)
        let outcome = try await rig.host.send("synthetic input", to: rig.binding.targetID)
        guard case .needsConfirmation(let readBack) = outcome else { Issue.record("expected confirmation"); return }
        await #expect(throws: RegistryError.contextualDeliveryUnsupported) {
            try await rig.host.send("synthetic input", context: rig.context, confirmedHash: readBack.hash)
        }
        #expect(await adapter.deliveries.isEmpty)
        #expect(try await rig.host.send("synthetic input", to: rig.binding.targetID, confirmedHash: readBack.hash) ==
            .delivered(["synthetic input"]))
    }

    @Test func confirmationAndExternalPolicyReloadStillApply() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter, tier: .confirm)
        let outcome = try await rig.host.send("synthetic input", context: rig.context)
        guard case .needsConfirmation(let readBack) = outcome else { Issue.record("expected confirmation"); return }
        #expect(await adapter.contextual.isEmpty)
        rig.store.overwrite(Policy())
        await #expect(throws: HostError.denied(.notAllowed(rig.binding.targetID))) {
            try await rig.host.send("synthetic input", context: rig.context, confirmedHash: readBack.hash)
        }
        #expect(await adapter.contextual.isEmpty)
    }

    @Test func validConfirmationStillUsesTheContextualAdapter() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter, tier: .confirm)
        let outcome = try await rig.host.send("synthetic input", context: rig.context)
        guard case .needsConfirmation(let readBack) = outcome else { Issue.record("expected confirmation"); return }
        #expect(try await rig.host.send("synthetic input", context: rig.context, confirmedHash: readBack.hash) ==
            .delivered(["synthetic input"]))
        #expect(await adapter.contextual.first?.context == rig.context)
        #expect(await adapter.legacy.isEmpty)
    }

    @Test func currentListingAndPolicyMustMatchTheContextBinding() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        await adapter.setTargets([AdapterTarget(name: "session", binding: "replacement-binding")])
        _ = try await rig.host.allow(rig.binding.targetID, tier: .open)
        await #expect(throws: HostError.denied(.rebound(rig.binding.targetID))) {
            try await rig.host.send("synthetic input", context: rig.context)
        }
        #expect(await adapter.contextual.isEmpty)
    }

    @Test func lockedDeniedAndSanitizationRefusedInputNeverReachesContextualAdapter() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter, tier: .locked)
        await #expect(throws: HostError.refused(.containsLineBreak)) {
            try await rig.host.send("one\ntwo", context: rig.context)
        }
        await #expect(throws: HostError.denied(.locked(rig.binding.targetID))) {
            try await rig.host.send("synthetic input", context: rig.context)
        }
        _ = try await rig.host.deny(rig.binding.targetID)
        await #expect(throws: HostError.denied(.notAllowed(rig.binding.targetID))) {
            try await rig.host.send("synthetic input", context: rig.context)
        }
        #expect(await adapter.contextual.isEmpty)
    }

    @Test func rateLimitAndLockdownRemainAuthoritative() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter, rate: 1)
        _ = try await rig.host.send("synthetic input", context: rig.context)
        await #expect(throws: HostError.self) { try await rig.host.send("synthetic input", context: rig.context) }
        await rig.host.engageLockdown(reason: "synthetic test")
        await #expect(throws: HostError.denied(.lockdown)) {
            try await rig.host.send("synthetic input", context: rig.context)
        }
        #expect(await adapter.contextual.count == 1)
    }

    @Test func legacyDeliveryDoesNotImplyContextualCapability() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        _ = try await rig.host.send("synthetic input", to: rig.binding.targetID)
        #expect(await adapter.legacy == ["synthetic input"])
        #expect(await adapter.contextual.isEmpty)
    }

    @Test func mismatchedProviderIsRejectedBeforeDispatch() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        let binding = try ProviderSessionBinding(hostID: "host-test", providerID: "other",
                                                targetID: rig.binding.targetID, sessionID: rig.binding.sessionID)
        let context = ProviderTurnContext(utteranceID: UUID(), connectionID: UUID(), binding: binding)
        await #expect(throws: ProviderContractError.wrongContext) {
            try await rig.host.send("synthetic input", context: context)
        }
        #expect(await adapter.contextual.isEmpty)
    }
}
