import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// The device side of ambient take-over (#366): the hello gives the device's class and advertises
/// `ambient_takeover`, and `ambient_moved_here` goes to ambient listening, never to the reply list.
@MainActor
@Suite struct HostConnectionAmbientTakeOverTests {
    @Test func theHelloGivesTheDeviceClassAndTheNoticeReachesAmbientListeningOnly() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() })
        var notices: [(HostEndpoint.Identifier, String?)] = []
        store.onAmbientMovedHere = { notices.append(($0, $1)) }
        await store.upsert(endpoint)
        await store.connect(endpoint.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        guard case .control(.hello(let info))? = try await socket.sentFrames().first?.payload else {
            Issue.record("expected the device hello first")
            return
        }
        #expect(info.capabilities.contains(AmbientTakeOver.capability))
        // The class only: these tests run on a Mac; an iPhone says `phone` and an iPad `pad`.
        #expect(info.deviceKind == AmbientHandoff.localDeviceKind)
        #expect(info.deviceKind.map { AmbientTakeOver.deviceKinds.contains($0) } ?? true)

        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["receive_replies"], deviceName: "Mac"
        )))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state == .ready } }
        let notice = Frame(timestamp: 1, source: "host", payload: .control(.ambientMovedHere(from: "phone")))
        try await socket.push(FrameCoding.encode(notice))
        try await waitUntil { await MainActor.run { notices.count == 1 } }
        #expect(notices.first?.0 == endpoint.id)
        #expect(notices.first?.1 == "phone")
        #expect(store.replyFrames.isEmpty)
        #expect(store.snapshots[endpoint.id]?.state == .ready)
        await store.disconnect(endpoint.id)
    }
}
