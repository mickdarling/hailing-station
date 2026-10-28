import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAppRefreshTests {
    @Test func refreshedEndpointKeepsTheRootDestinationOnlyWithACurrentAppliedBinding() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let old = try rig.currentBinding()
        let remembered = DestinationSelection(hostID: rig.endpoint.id, hostURL: rig.endpoint.url.absoluteString,
                                              targetID: rig.target.id, targetName: rig.target.name)
        try await rig.drop()
        var refreshed = rig.endpoint
        refreshed.url = try #require(URL(string: "ws://127.0.0.1:18766"))
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: refreshed.url)
        await rig.store.upsert(refreshed)
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        try await rig.feed()
        let presentation = rig.appPresentation
        let destinationExists = presentation.matches(remembered, endpoint: refreshed, target: rig.target)
        #expect(destinationExists)
        let refreshedSelection = try #require(presentation.restoredSelection(
            remembered, endpoint: refreshed, target: rig.target))
        #expect(refreshedSelection.hostURL == refreshed.url.absoluteString)
        #expect(refreshedSelection.hostID == remembered.hostID && refreshedSelection.targetID == remembered.targetID)
        if !destinationExists { await rig.controller.destinationLost() }
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        let stale = AmbientRestorePresentation(controller: rig.controller, confirmedBinding: old)
        #expect(!stale.matches(remembered, endpoint: refreshed, target: rig.target))
        var renamed = rig.target
        renamed.name = "Another synthetic target"
        #expect(!presentation.matches(remembered, endpoint: refreshed, target: renamed))
        let other = try endpoint("other-synthetic-host", refreshed.url.absoluteString)
        #expect(!presentation.matches(remembered, endpoint: other, target: rig.target))
        await rig.close()
        #expect(!rig.appPresentation.matches(remembered, endpoint: refreshed, target: rig.target))
    }
}
