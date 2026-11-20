#if os(macOS)
import Foundation
import SwiftUI
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct NativeListeningSettingsTests {
    @Test(arguments: [false, true])
    func visitingPreservesPreferencesAndDoesNotCreateAnAmbientOwner(mask: Bool) async throws {
        let suite = "hail-listening-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if mask { defaults.set(true, forKey: "ambient.masksDuringReplies") }
        let connector = ScriptedConnector()
        let store = HostConnectionStore(connector: connector)
        let fixture = ListeningSettingsFixture(store: store)
        let host = NativeStationToolHost(ListeningSettingsFixtureView(fixture: fixture, defaults: defaults))
        defer { host.finish() }
        try await host.appeared()
        await host.render()
        let page = try #require(fixture.page)
        #expect(page.connections === store && page.masksDuringReplies == mask)
        host.push()
        await host.render()
        try await host.back()
        #expect(store.ambientController == nil && !store.ambientStreaming)
        let opened = await connector.opens
        #expect(fixture.navigation.isEmpty && opened.isEmpty)
        if mask {
            #expect(defaults.bool(forKey: "ambient.masksDuringReplies"))
        } else {
            #expect(defaults.object(forKey: "ambient.masksDuringReplies") == nil)
        }
    }

    @Test func explicitPreferenceAndManageIntentsUseOnlyTheSuppliedBindingAndNavigation() async throws {
        let suite = "hail-listening-intent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ListeningSettingsFixture(store: HostConnectionStore())
        let host = NativeStationToolHost(ListeningSettingsFixtureView(fixture: fixture, defaults: defaults))
        defer { host.finish() }
        try await host.appeared()
        let page = try #require(fixture.page)
        page.apply(.setMaskPreference(true))
        await host.render()
        #expect(defaults.bool(forKey: "ambient.masksDuringReplies"))
        page.apply(.manageInStation)
        #expect(fixture.navigation == [.select(.station)])
        #expect(fixture.store.ambientController == nil && !fixture.store.ambientStreaming)
        page.apply(.setMaskPreference(false))
        #expect(!defaults.bool(forKey: "ambient.masksDuringReplies"))
    }

    @Test func aRequestedStartDoesNotBecomeStreamingOrClaimTheMicrophoneIsOff() async throws {
        #expect(ListeningSettingsState(controller: nil).activity == .unavailable)
        let probe = ListeningSettingsAmbientProbe()
        #expect(ListeningSettingsState(controller: probe.controller).activity == .off)
        probe.permissionDecision = nil
        let start = Task { await probe.controller.turnOn(for: ListeningSettingsAmbientProbe.binding) }
        defer { probe.resolvePermission(false) }
        try await waitUntil { await MainActor.run { probe.permissionRequests == 1 } }
        let state = ListeningSettingsState(controller: probe.controller)
        #expect(state.requestedOn == true && state.activity == .requested)
        #expect(!probe.controller.isListening && probe.capture.startCount == 0 && probe.streamerCreations == 0)
        probe.resolvePermission(false)
        await start.value
        #expect(ListeningSettingsState(controller: probe.controller).activity == .off)
    }

    @Test func mountingAndLeavingPreserveAnAlreadyStreamingSyntheticOwner() async throws {
        let probe = ListeningSettingsAmbientProbe()
        await probe.controller.turnOn(for: ListeningSettingsAmbientProbe.binding)
        #expect(ListeningSettingsState(controller: probe.controller).activity == .streaming)
        let store = HostConnectionStore()
        store.ambientController = probe.controller
        var preferencesWritten = 0
        var manageRequests = 0
        let page = ListeningSettingsOverview(connections: store, masksDuringReplies: Binding(
            get: { false }, set: { _ in preferencesWritten += 1 }
        )) { manageRequests += 1 }
        let host = NativeStationToolHost(page)
        defer { host.finish() }
        try await host.appeared()
        await host.render()
        host.push()
        await host.render()
        #expect(store.ambientController === probe.controller && probe.controller.isListening)
        #expect(probe.permissionRequests == 1 && probe.streamerCreations == 1 && probe.releases == 0)
        #expect(probe.capture.startCount == 1 && probe.capture.stopCount == 0)
        #expect(preferencesWritten == 0 && manageRequests == 0)
        await probe.controller.turnOff()
    }
}
#endif
