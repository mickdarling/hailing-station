import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectReauthorizationTests {
    @Test func refreshedConnectionRequiringOwnerAuthorizationHasAnExplicitReason() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        var refreshed = rig.endpoint
        refreshed.url = try #require(URL(string: "ws://127.0.0.1:18768"))
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: refreshed.url)
        await rig.store.upsert(refreshed)
        try await waitUntil { try await rig.socket.sentFrames().contains {
            if case .control(.hello) = $0.payload { return true }; return false
        } }
        try await rig.socket.push(.hello(HelloInfo(versions: [ProtocolVersion.current],
            capabilities: ["ping", "stream_audio", "set_privacy"], deviceName: "Synthetic")))
        try await rig.socket.push(.targets([rig.target]))
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        let notice = try #require(rig.notices.first)
        #expect(rig.notices.count == 1 && notice.outcome == .blocked && notice.reason == .reauthorizationNeeded)
        #expect(notice.reason?.diagnosticToken == "reauthorization_needed")
        #expect(notice.text.contains("re-authorization needed") && !notice.text.contains("tap to resume"))
        #expect(rig.store.ambientBinding(host: rig.endpoint.id, targetID: rig.target.id) == nil)
        #expect(try await audioFrames(rig.socket).isEmpty)
        await rig.close()
    }
}
