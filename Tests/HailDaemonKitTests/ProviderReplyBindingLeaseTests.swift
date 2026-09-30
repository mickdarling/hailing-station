import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderReplyBindingLeaseTests {
    @Test func cooperativeRebindRetiresOldLeaseAndRestoringNameCannotReviveIt() async throws {
        let adapter = SyntheticBindingLeaseAdapter(kind: "lease")
        let registry = Registry()
        try await registry.register(adapter)
        let original = try leaseBinding(provider: "lease")
        let lease = try await registry.acquireReplyBindingLease(original)
        #expect(lease.binding == original)
        #expect(lease.performIfCurrent { true } == true)
        await adapter.rebind("replacement")
        #expect(lease.performIfCurrent { true } == nil)
        await adapter.rebind("session")
        #expect(lease.performIfCurrent { true } == nil)
        let restored = try await registry.acquireReplyBindingLease(original)
        #expect(restored.performIfCurrent { true } == true)
    }

    @Test func providersHaveIndependentPublicationGates() async throws {
        let first = SyntheticBindingLeaseAdapter(kind: "first")
        let second = SyntheticBindingLeaseAdapter(kind: "second")
        let registry = Registry()
        try await registry.register(first)
        try await registry.register(second)
        let firstLease = try await registry.acquireReplyBindingLease(leaseBinding(provider: "first"))
        let secondLease = try await registry.acquireReplyBindingLease(leaseBinding(provider: "second"))
        await first.rebind("replacement")
        #expect(firstLease.performIfCurrent { true } == nil)
        #expect(secondLease.performIfCurrent { true } == true)
    }

    @Test func returnedLeaseMustMatchEveryRequestedIdentityField() async throws {
        let original = try leaseBinding(provider: "lease")
        for field in ["host", "provider", "target", "session", "observation"] {
            let adapter = SyntheticBindingLeaseAdapter(kind: "lease")
            await adapter.override(try leaseBinding(provider: "lease", replacing: field))
            let registry = Registry()
            try await registry.register(adapter)
            await #expect(throws: ProviderContractError.wrongContext) {
                try await registry.acquireReplyBindingLease(original)
            }
        }
    }

    @Test func unregisteredOrWrongProviderNeverCallsLeaseCapability() async throws {
        let adapter = SyntheticBindingLeaseAdapter(kind: "lease")
        let registry = Registry()
        try await registry.register(adapter)
        let wrong = try ProviderSessionBinding(
            hostID: "host", providerID: "other", targetID: "lease:target", sessionID: "session"
        )
        await #expect(throws: ProviderContractError.wrongContext) {
            try await registry.acquireReplyBindingLease(wrong)
        }
        await #expect(throws: RegistryError.unknownTarget("missing:target")) {
            try await registry.acquireReplyBindingLease(leaseBinding(provider: "missing"))
        }
        #expect(await adapter.acquisitions == 0)
    }

    @Test func genericAndTmuxReplyAdaptersNeverReceiveFictitiousLease() async throws {
        let runner = FakeCommandRunner { _ in CommandResult(exitCode: 0, stdout: "") }
        let tmux = TmuxAdapter(runner: runner, pollInterval: nil)
        let bridge = try TmuxReplyAdapter(terminal: tmux, targets: ["target"])
        let registry = Registry()
        try await registry.register(tmux)
        try await registry.register(bridge)
        for provider in ["tmux", "tmux-reply"] {
            await #expect(throws: RegistryError.replyBindingLeaseUnsupported) {
                try await registry.acquireReplyBindingLease(leaseBinding(provider: provider))
            }
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test func cancelledAcquisitionIsRefusedBeforeCallingProvider() async throws {
        let adapter = SyntheticBindingLeaseAdapter(kind: "lease")
        let registry = Registry()
        try await registry.register(adapter)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await registry.acquireReplyBindingLease(leaseBinding(provider: "lease"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await adapter.acquisitions == 0)
    }

    @Test func revocationDuringSuspendedAcquisitionRejectsReturnedStaleLease() async throws {
        let adapter = SyntheticBindingLeaseAdapter(kind: "lease")
        let registry = Registry()
        try await registry.register(adapter)
        await adapter.holdAcquisition()
        let task = Task { try await registry.acquireReplyBindingLease(leaseBinding(provider: "lease")) }
        await adapter.waitForAcquisition()
        await adapter.rebind("replacement")
        await adapter.releaseAcquisition()
        await #expect(throws: ProviderContractError.turnEnded) { try await task.value }
    }

    @Test func cancellationDuringSuspendedAcquisitionRejectsReturnedLease() async throws {
        let adapter = SyntheticBindingLeaseAdapter(kind: "lease")
        let registry = Registry()
        try await registry.register(adapter)
        await adapter.holdAcquisition()
        let task = Task { try await registry.acquireReplyBindingLease(leaseBinding(provider: "lease")) }
        await adapter.waitForAcquisition()
        task.cancel()
        await adapter.releaseAcquisition()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private func leaseBinding(provider: String, replacing field: String = "none") throws -> ProviderSessionBinding {
    try ProviderSessionBinding(
        hostID: field == "host" ? "other-host" : "host",
        providerID: field == "provider" ? "other" : provider,
        targetID: field == "target" ? "\(provider):other" : "\(provider):target",
        sessionID: field == "session" ? "other-session" : "session",
        observationID: field == "observation" ? UUID() : leaseObservation
    )
}

private let leaseObservation = UUID()

/// Rebinding first invalidates the shared gate; no external tmux authority is simulated by polling.
private actor SyntheticBindingLeaseAdapter: ProviderReplyBindingLeasing {
    nonisolated let kind: String
    private let authority = ReplyPublicationAuthority()
    private var sessionID = "session"
    private var wrongBinding: ProviderSessionBinding?
    private var held = false
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private(set) var acquisitions = 0

    init(kind: String) { self.kind = kind }
    func listTargets() async throws -> [AdapterTarget] { [AdapterTarget(name: "target", binding: sessionID)] }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {}

    func acquireReplyBindingLease(_ binding: ProviderSessionBinding) async throws -> ProviderReplyBindingLease {
        acquisitions += 1
        guard binding.sessionID == sessionID else { throw ProviderContractError.wrongContext }
        let lease = ProviderReplyBindingLease(binding: wrongBinding ?? binding, permit: authority.issuePermit())
        if held {
            entered = true
            arrival?.resume()
            arrival = nil
            await withCheckedContinuation { release = $0 }
        }
        return lease
    }
    func rebind(_ sessionID: String) { authority.invalidate(); self.sessionID = sessionID }
    func override(_ binding: ProviderSessionBinding) { wrongBinding = binding }
    func holdAcquisition() { held = true }
    func waitForAcquisition() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func releaseAcquisition() { held = false; release?.resume(); release = nil }
}
