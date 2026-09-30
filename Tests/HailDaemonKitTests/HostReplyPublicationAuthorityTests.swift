import Testing
@testable import HailDaemonKit

@Suite struct HostReplyPublicationAuthorityTests {
    private let target = "tmux:synthetic"
    private let sessionID = "synthetic-binding"

    private struct Fixture {
        let host: HailHost
        let store: InMemoryPolicyStore
        let binding: ProviderSessionBinding
    }

    private func fixture(store supplied: InMemoryPolicyStore? = nil) async throws -> Fixture {
        let registry = Registry()
        try await registry.register(FakeAdapter(
            kind: "tmux", targets: [AdapterTarget(name: "synthetic", binding: sessionID)]
        ))
        var policy = Policy()
        try policy.allow(target, binding: sessionID, tier: .open)
        let store = supplied ?? InMemoryPolicyStore(policy)
        let binding = try ProviderSessionBinding(
            hostID: "synthetic-host", providerID: "tmux", targetID: target, sessionID: sessionID
        )
        return Fixture(host: try HailHost(registry: registry, store: store), store: store, binding: binding)
    }

    @Test func grantChecksExactBindingTierAndAvailableAuthorityInOneActorTurn() async throws {
        let fixture = try await fixture()
        let permit = try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
        #expect(permit.performIfCurrent { true } == true)
        let other = try ProviderSessionBinding(
            hostID: "synthetic-host", providerID: "tmux", targetID: target, sessionID: "other-binding"
        )
        #expect(await fixture.host.replyPublicationPermit(for: other) == nil)
        _ = try await fixture.host.setTier(.confirm, for: target)
        #expect(permit.performIfCurrent { true } == nil)
        #expect(await fixture.host.replyPublicationPermit(for: fixture.binding) != nil)
        _ = try await fixture.host.setTier(.locked, for: target)
        #expect(await fixture.host.replyPublicationPermit(for: fixture.binding) == nil)
    }

    @Test func completedDenialAndRestoredGrantNeverReviveOldPermit() async throws {
        let fixture = try await fixture()
        let permit = try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
        #expect(try await fixture.host.deny(target))
        #expect(permit.performIfCurrent { true } == nil)
        #expect(await fixture.host.replyPublicationPermit(for: fixture.binding) == nil)
        _ = try await fixture.host.allow(target, tier: .open)
        #expect(permit.performIfCurrent { true } == nil)
        #expect(try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
            .performIfCurrent { true } == true)
    }

    @Test func dispatchReloadOfChangedPolicyRevokesPermit() async throws {
        let fixture = try await fixture()
        let permit = try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
        fixture.store.overwrite(Policy())
        await #expect(throws: HostError.denied(.notAllowed(target))) {
            try await fixture.host.send("synthetic input", to: target)
        }
        #expect(permit.performIfCurrent { true } == nil)
        #expect(await fixture.host.replyPublicationPermit(for: fixture.binding) == nil)
    }

    @Test func observedReloadFailureRevokesPermitAndRecoveryOnlyIssuesNewAuthority() async throws {
        let fixture = try await fixture()
        let permit = try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
        fixture.store.setLoadError(PolicyFileError.malformed("synthetic failure"))
        await #expect(throws: HostError.policyUnavailable("malformed(\"synthetic failure\")")) {
            try await fixture.host.send("synthetic input", to: target)
        }
        #expect(permit.performIfCurrent { true } == nil)
        #expect(await fixture.host.replyPublicationPermit(for: fixture.binding) == nil)
        fixture.store.setLoadError(nil)
        #expect(try await fixture.host.send("synthetic input", to: target) == .delivered(["synthetic input"]))
        #expect(permit.performIfCurrent { true } == nil)
        #expect(try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
            .performIfCurrent { true } == true)
    }

    @Test func invalidCommittedPolicyAndInitialLoadFailureRefuseAuthority() async throws {
        var original = Policy()
        try original.allow(target, binding: sessionID, tier: .open)
        let invalid = Policy(guardPatterns: [GuardPattern(name: "synthetic", regex: "[")])
        let fixture = try await fixture(store: InMemoryPolicyStore(original, returnedPolicy: invalid))
        let permit = try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
        await #expect(throws: PolicyFormatError.invalidGuardPattern("synthetic")) {
            try await fixture.host.setTier(.confirm, for: target)
        }
        #expect(permit.performIfCurrent { true } == nil)
        #expect(await fixture.host.replyPublicationPermit(for: fixture.binding) == nil)
        let unavailable = try await self.fixture(store: InMemoryPolicyStore(
            loadError: PolicyFileError.malformed("synthetic unavailable")
        ))
        #expect(await unavailable.host.replyPublicationPermit(for: unavailable.binding) == nil)
    }

    @Test func completedLockdownRevokesPermitWithoutAffectingAnotherHost() async throws {
        let first = try await fixture()
        let second = try await fixture()
        let revoked = try #require(await first.host.replyPublicationPermit(for: first.binding))
        let independent = try #require(await second.host.replyPublicationPermit(for: second.binding))
        #expect(await first.host.engageLockdown(reason: "synthetic trigger") != nil)
        #expect(revoked.performIfCurrent { true } == nil)
        #expect(await first.host.replyPublicationPermit(for: first.binding) == nil)
        #expect(independent.performIfCurrent { true } == true)
    }

    @Test func failedSaveRetiresReplyPermitEvenWhenStoredPolicyIsUnchanged() async throws {
        var original = Policy()
        try original.allow(target, binding: sessionID, tier: .open)
        let failure = PolicyFileError.unwritable("synthetic persistence failure")
        let unchanged = try await fixture(store: InMemoryPolicyStore(original, saveError: failure))
        let retained = try #require(await unchanged.host.replyPublicationPermit(for: unchanged.binding))
        await #expect(throws: failure) { try await unchanged.host.deny(target) }
        #expect(retained.performIfCurrent { true } == nil)
        #expect(await unchanged.host.currentPolicy == original)
        #expect(try #require(await unchanged.host.replyPublicationPermit(for: unchanged.binding))
            .performIfCurrent { true } == true)
        let committed = try await fixture(store: InMemoryPolicyStore(original, durabilityFailure: failure))
        let revoked = try #require(await committed.host.replyPublicationPermit(for: committed.binding))
        await #expect(throws: failure) { try await committed.host.deny(target) }
        #expect(revoked.performIfCurrent { true } == nil)
        #expect(await committed.host.replyPublicationPermit(for: committed.binding) == nil)
    }

    @Test func unchangedFailedSavePreservesGenericConfirmationWhileRetiringReplyPermit() async throws {
        var original = Policy()
        try original.allow(target, binding: sessionID, tier: .confirm)
        let failure = PolicyFileError.unwritable("synthetic persistence failure")
        let fixture = try await fixture(store: InMemoryPolicyStore(original, saveError: failure))
        guard case .needsConfirmation(let readBack) = try await fixture.host.send("synthetic input", to: target) else {
            Issue.record("expected synthetic confirmation")
            return
        }
        let permit = try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
        await #expect(throws: failure) { try await fixture.host.deny(target) }
        #expect(permit.performIfCurrent { true } == nil)
        #expect(try await fixture.host.send("synthetic input", to: target, confirmedHash: readBack.hash)
            == .delivered(["synthetic input"]))
    }

    @Test func failedTransactionLoadRevokesPermitAndRefusesNewAuthorityUntilRecovery() async throws {
        let fixture = try await fixture()
        let permit = try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
        let failure = PolicyFileError.malformed("synthetic transaction failure")
        fixture.store.setLoadError(failure)
        await #expect(throws: failure) { try await fixture.host.deny(target) }
        #expect(permit.performIfCurrent { true } == nil)
        #expect(await fixture.host.policyFailure != nil)
        #expect(await fixture.host.replyPublicationPermit(for: fixture.binding) == nil)
        fixture.store.setLoadError(nil)
        _ = try await fixture.host.allow(target, tier: .open)
        #expect(permit.performIfCurrent { true } == nil)
        #expect(try #require(await fixture.host.replyPublicationPermit(for: fixture.binding))
            .performIfCurrent { true } == true)
    }
}
