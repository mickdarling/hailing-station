#if os(macOS)
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct PrivacySettingsErrorTests {
    @Test func acceptedOverheardChangesClearOnlyTheirOwnValidationError() {
        let connector = ScriptedConnector()
        let owner = PrivacySettingsFixture(connections: HostConnectionStore(connector: connector), host: nil)
        owner.privacySettingsRequest.failure = "Privacy request failed"
        owner.performPrivacySettings(.whoseOverheard("unknown-future-scope"))
        #expect(owner.privacySettingsState().overheardFailure != nil)
        #expect(owner.privacySettingsState().failure == "Privacy request failed")
        owner.performPrivacySettings(.whoseOverheard("owner"))
        #expect(owner.privacySettingsState().overheardFailure == nil)
        #expect(owner.privacySettingsState().failure == "Privacy request failed")
        owner.settingsWhoseOverheard = "unknown-future-scope"
        owner.performPrivacySettings(.showOverheard(true))
        #expect(owner.privacySettingsState().overheardFailure != nil && !owner.settingsShowOverheard)
        owner.performPrivacySettings(.showOverheard(false))
        #expect(owner.privacySettingsState().overheardFailure == nil)
        #expect(owner.privacySettingsState().failure == "Privacy request failed")
        #expect(owner.connections.overheardScope == "off")
    }

    @Test func aSuccessfulPrivacySendClearsOnlyPrivacyErrorAfterTheSendCompletes() async throws {
        let rig = try await PrivacySettingsRig.ready(capabilities: [DuckMode.privacySwitchCapability])
        try await rig.confirmPrivateButUnavailable()
        let host = try #require(rig.owner.privacySettingsState().host)
        rig.owner.privacySettingsRequest.failure = "Previous Privacy request failed"
        rig.owner.privacySettingsRequest.overheardFailure = "Overheard scope not supported"
        await rig.transport.holdPrivacySends()
        rig.owner.performPrivacySettings(.privacy(false, host: host.id, generation: host.connectionGeneration))
        try await waitUntil { await rig.transport.privacyAttempts == 1 }
        #expect(rig.owner.privacySettingsState().failure == "Previous Privacy request failed")
        #expect(rig.owner.privacySettingsState().privacy.pending)
        await rig.transport.releasePrivacySends()
        try await waitUntil { await MainActor.run { rig.owner.privacySettingsState().failure == nil } }
        #expect(rig.owner.privacySettingsState().overheardFailure == "Overheard scope not supported")
        #expect(rig.owner.privacySettingsState().privacy.pending, "A completed send is not host confirmation")
        #expect(!rig.owner.privacySettingsState().privacy.isPrivate)
        await rig.close()
    }

    @Test func aPendingDuplicateKeepsTheInflightRequestIDAndItsEventualTransportError() async throws {
        let rig = try await PrivacySettingsRig.ready(
            capabilities: [DuckMode.privacySwitchCapability], declinePrivacy: true)
        try await rig.confirmPrivateButUnavailable()
        let host = try #require(rig.owner.privacySettingsState().host)
        rig.owner.privacySettingsRequest.overheardFailure = "Overheard scope not supported"
        await rig.transport.holdPrivacySends()
        rig.owner.performPrivacySettings(.privacy(false, host: host.id, generation: host.connectionGeneration))
        try await waitUntil { await rig.transport.privacyAttempts == 1 }
        let request = rig.owner.privacySettingsRequest.id
        rig.owner.performPrivacySettings(.privacy(false, host: host.id, generation: host.connectionGeneration))
        #expect(rig.owner.privacySettingsRequest.id == request)
        #expect(rig.owner.privacySettingsState().failure == nil)
        await rig.transport.releasePrivacySends()
        try await waitUntil { await MainActor.run { rig.owner.privacySettingsState().failure != nil } }
        #expect(rig.owner.privacySettingsRequest.id == request)
        #expect(rig.owner.privacySettingsState().failure?.contains("failed:") == true)
        #expect(rig.owner.privacySettingsState().overheardFailure == "Overheard scope not supported")
        #expect(await rig.transport.privacyAttempts == 1)
        await rig.close()
    }
}
#endif
