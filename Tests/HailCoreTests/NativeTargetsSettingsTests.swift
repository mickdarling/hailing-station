#if os(macOS)
import Foundation
import SwiftUI
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct NativeTargetsSettingsTests {
    @Test func mountingCoveringAndReturningNeverConnectSelectPersistOrOpenTools() async throws {
        let connector = ScriptedConnector()
        let store = HostConnectionStore(connector: connector)
        let endpoint = try HostEndpoint(
            id: "example-mac", name: "Example Mac", url: #require(URL(string: "ws://127.0.0.1:8765")))
        await store.upsert(endpoint) // The root already owns this configured, disconnected Mac.
        let original = store.hosts
        var destinationRequests = 0
        var setupAppearances = 0
        let page = TargetsSettingsOverview(
            store: store, availability: .offline, confirmed: nil, remembered: nil,
            send: { _ in destinationRequests += 1 },
            setup: { Text("Existing Mac Setup").onAppear { setupAppearances += 1 } }
        )
        #expect(page.store === store)
        let host = NativeStationToolHost(page)
        defer { host.finish() }
        try await host.appeared()
        await host.render()
        #expect(store.hosts == original)
        #expect(store.ambientController == nil && !store.ambientStreaming)
        #expect(await connector.openCount(for: endpoint.url) == 0)
        host.push()
        await host.render()
        try await host.back()
        await host.render()
        #expect(store.hosts == original)
        #expect(await connector.openCount(for: endpoint.url) == 0)
        #expect(destinationRequests == 0 && setupAppearances == 0)
    }

    @Test func anExplicitDestinationRequestChangesOnlyNavigation() async throws {
        let connector = ScriptedConnector()
        let store = HostConnectionStore(connector: connector)
        var intents: [StationNavigationIntent] = []
        let page = TargetsSettingsOverview(
            store: store, availability: .unconfigured, confirmed: nil, remembered: nil,
            send: { intents.append($0) }, setup: { Text("Existing Mac Setup") }
        )
        let original = store.hosts
        page.apply(.chooseDestinationInStation)
        #expect(intents == [.select(.station)])
        #expect(store.hosts == original && store.ambientController == nil && !store.ambientStreaming)
        #expect(await connector.opens.isEmpty)
    }
}
#endif
