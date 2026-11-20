#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct PrivacySettingsOwnerTests {
    private static let privacy = [DuckMode.privacySwitchCapability]

    @Test func mountingUpdatingAndLeavingDoNotApplySavedPreferencesOrSendPrivacy() async throws {
        let rig = try await PrivacySettingsRig.ready(capabilities: [AmbientOverheard.capability])
        try await waitUntil { try await rig.scopes() == ["off"] }
        rig.owner.settingsShowOverheard = true
        rig.owner.settingsWhoseOverheard = "everyone"
        rig.owner.preferenceWrites = []
        let initialFrames = try await rig.socket.sentFrames()
        let host = NativePrivacySettingsHost(owner: rig.owner)
        defer { host.finish() }
        await host.render()
        #expect(rig.owner.privacySettingsState().requestedScope == "off")
        #expect(rig.owner.preferenceWrites.isEmpty)
        #expect(try await rig.socket.sentFrames() == initialFrames)
        rig.owner.privacySettingsRequest.failure = "Synthetic previously declined request"
        await host.render()
        host.hide()
        await host.render()
        #expect(rig.owner.preferenceWrites.isEmpty)
        #expect(try await rig.socket.sentFrames() == initialFrames)
        #expect(await rig.transport.privacyAttempts == 0)
        await rig.close()
    }

    @Test func explicitOverheardChangesUseTheExistingSameValueGuard() async throws {
        let rig = try await PrivacySettingsRig.ready(capabilities: [AmbientOverheard.capability])
        try await waitUntil { try await rig.scopes() == ["off"] }
        rig.owner.performPrivacySettings(.whoseOverheard("everyone"))
        #expect(rig.owner.settingsWhoseOverheard == "everyone")
        #expect(rig.owner.connections.overheardScope == "off", "Changing whose while hidden cannot broaden scope")
        rig.owner.performPrivacySettings(.showOverheard(true))
        // The unchanged mounted station control can react to the same AppStorage change. Its same-value call must
        // not enqueue another send; this exercises the real HostConnectionStore guard, not a fake implementation.
        rig.owner.connections.setOverheardScope("everyone")
        try await waitUntil { try await rig.scopes() == ["off", "everyone"] }
        rig.owner.performPrivacySettings(.whoseOverheard("all"))
        #expect(rig.owner.settingsWhoseOverheard == "everyone")
        #expect(rig.owner.connections.overheardScope == "everyone")
        #expect(rig.owner.privacySettingsRequest.overheardFailure != nil)
        rig.owner.performPrivacySettings(.showOverheard(false))
        #expect(rig.owner.privacySettingsRequest.overheardFailure == nil)
        try await waitUntil { try await rig.scopes() == ["off", "everyone", "off"] }
        await rig.close()
        #expect(try await rig.scopes() == ["off", "everyone", "off"])
    }

    @Test func unknownOverheardPreferenceCannotBeEnabledImplicitly() {
        let owner = PrivacySettingsFixture(
            connections: HostConnectionStore(connector: ScriptedConnector()), host: nil)
        owner.settingsWhoseOverheard = "unknown-future-scope"
        owner.preferenceWrites = []
        owner.performPrivacySettings(.showOverheard(true))
        #expect(!owner.settingsShowOverheard && owner.connections.overheardScope == "off")
        #expect(owner.preferenceWrites.isEmpty && owner.privacySettingsRequest.overheardFailure != nil)
        #expect(!owner.privacySettingsState().knowsWhose)
    }

    @Test func unsupportedAndStaleRequestsNeverReachTheTransport() async throws {
        let rig = try await PrivacySettingsRig.ready(capabilities: [])
        let host = try #require(rig.owner.privacySettingsState().host)
        #expect(!rig.owner.privacySettingsState().canRequestPrivacy)
        rig.owner.performPrivacySettings(.privacy(true, host: host.id, generation: host.connectionGeneration))
        try await waitUntil { await MainActor.run { rig.owner.privacySettingsRequest.failure != nil } }
        #expect(await rig.transport.privacyAttempts == 0)
        await rig.close()
        #expect(rig.owner.privacySettingsState().privacy.shown == .unconfirmed)

        let capable = try await PrivacySettingsRig.ready(capabilities: Self.privacy)
        try await capable.confirmPrivateButUnavailable()
        #expect(capable.owner.privacySettingsState().canRequestPrivacy)
        capable.owner.performPrivacySettings(.privacy(false, host: capable.endpoint.id, generation: UUID()))
        try await waitUntil { await MainActor.run { capable.owner.privacySettingsRequest.failure != nil } }
        #expect(await capable.transport.privacyAttempts == 0)
        await capable.close()
    }

    @Test func explicitPrivacyRequestWaitsForConfirmationAndRechecksExpiry() async throws {
        let rig = try await PrivacySettingsRig.ready(capabilities: Self.privacy)
        try await rig.confirmPrivateButUnavailable()
        let initial = rig.owner.privacySettingsState()
        #expect(initial.privacy.shown == .privateListeningUnavailable && initial.canRequestPrivacy)
        let host = try #require(initial.host)
        rig.owner.performPrivacySettings(.privacy(false, host: host.id, generation: host.connectionGeneration))
        try await waitUntil { await MainActor.run { rig.owner.privacySettingsState().privacy.pending } }
        let waiting = rig.owner.privacySettingsState()
        #expect(!waiting.privacy.isPrivate && !waiting.canRequestPrivacy)
        #expect(rig.owner.privacySettingsState(now: Date().addingTimeInterval(11)).privacy.isPrivate)
        try await rig.socket.push(.duckMode(on: false, reason: "device"))
        try await waitUntil { await MainActor.run {
            rig.owner.privacySettingsState().privacy.shown == .confirmedNotPrivate
        } }
        let confirmed = rig.owner.privacySettingsState()
        #expect(!confirmed.canRequestPrivacy, "The existing exception ends once privacy-off is confirmed")
        #expect(!confirmed.privacyDetail.contains("recording and sending requests"))
        #expect(await rig.transport.privacyAttempts == 1)
        await rig.close()
    }

    @Test func aDeclinedOwnerRequestStaysVisibleWithoutOptimisticPrivacy() async throws {
        let rig = try await PrivacySettingsRig.ready(capabilities: Self.privacy, declinePrivacy: true)
        try await rig.confirmPrivateButUnavailable()
        let host = try #require(rig.owner.privacySettingsState().host)
        rig.owner.performPrivacySettings(.privacy(false, host: host.id, generation: host.connectionGeneration))
        try await waitUntil { await MainActor.run { rig.owner.privacySettingsRequest.failure != nil } }
        #expect(rig.owner.privacySettingsRequest.failure?.contains("failed:") == true)
        #expect(!rig.owner.privacySettingsState().privacy.pending)
        #expect(await rig.transport.privacyAttempts == 1)
        await rig.close()
    }
}
#endif
