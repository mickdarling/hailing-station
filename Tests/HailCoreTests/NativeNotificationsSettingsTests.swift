#if os(macOS)
import HailCore
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct NativeNotificationsSettingsTests {
    @Test func mountingCoveringAndReturningNeverReadAndAnExplicitReadSurvivesBeingHidden() async throws {
        let reader = NotificationAccessReaderSpy()
        let owner = NotificationAccessModel(read: { await reader.read() })
        let page = NotificationsSettingsOverview(model: owner)
        let host = NativeStationToolHost(page)
        defer { host.finish() }
        try await host.appeared()
        await host.render()
        host.push()
        await host.render()
        try await host.back()
        await host.render()
        #expect(await reader.calls == 0)
        #expect(page.model === owner && owner.status == nil && !owner.isChecking)
        page.apply(.checkAccess)
        try await waitUntil { await reader.calls == 1 }
        page.apply(.checkAccess)
        host.push()
        await host.render()
        try await reader.finish(1, with: .authorized)
        try await waitUntil { await MainActor.run { owner.status == .authorized && !owner.isChecking } }
        try await host.back()
        await host.render()
        #expect(page.model === owner && owner.status == .authorized)
        #expect(await reader.calls == 1, "Hiding, returning and a duplicate intent cannot start another read")
    }

    @Test func stationResourcesKeepTheStatusOwnerWithoutStartingACheck() {
        let resources = StationResources(
            connections: HostConnectionStore(connector: ScriptedConnector()),
            backend: FakeAudioSessionBackend(inputs: []), player: FormatTestPlayer(),
            keepaliveRenderer: FakeKeepaliveRenderer())
        let owner = resources.notificationAccess
        let page = NotificationsSettingsOverview(model: owner)
        #expect(page.model === resources.notificationAccess)
        #expect(owner.status == nil && !owner.isChecking)
    }
}
#endif
