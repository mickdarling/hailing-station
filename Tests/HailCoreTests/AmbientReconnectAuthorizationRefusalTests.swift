import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAuthorizationRefusalTests {
    @Test func explicitAuthorizationRefusalRequiresAnActionableOwnerNotice() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        var refreshed = rig.endpoint
        refreshed.name = "Refreshed owner-authorized host"
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: refreshed.url)
        await rig.store.upsert(refreshed)
        try await rig.handshake(rig.socket)
        try await waitUntil { try await rig.selectionPing(after: 0) != nil }
        try await rig.socket.push(.error(code: .unauthorized,
            message: "retained selection requires owner authorization"))
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        let notice = try #require(rig.notices.first)
        #expect(rig.notices.count == 1 && notice.reason == .reauthorizationNeeded)
        #expect(notice.reason?.diagnosticToken == "reauthorization_needed")
        #expect(notice.text.contains("re-authorization needed"))
        #expect(try await audioFrames(rig.socket).isEmpty)
        await rig.close()
    }
}
