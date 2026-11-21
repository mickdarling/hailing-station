import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct RouteSnapshotCompatibilityTests {
    @Test(arguments: [false, true])
    func legacyHostReceivesCompatibleRouteEvents(advertisesSnapshots: Bool) async throws {
        let host = try endpoint(), socket = ScriptedSocket(), connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: host.url)
        let connection = HostConnection(endpoint: host, connector: connector)
        await connection.connect()
        try await waitUntil { try await socket.sentFrames().count == 1 }
        let capabilities = [DiagnosticLimits.capability]
            + (advertisesSnapshots ? [DiagnosticLimits.routeSnapshotCapability] : [])
        try await socket.push(.hello(HelloInfo(versions: [1], capabilities: capabilities, deviceName: "Mac")))
        try await waitUntil { await connection.snapshot.state == .ready }

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/schema/route-snapshot.example.json"))
        guard case .control(.diagnostic(let events)) = try FrameCoding.decode(bytes).payload else {
            Issue.record("expected diagnostic fixture")
            return
        }
        try await connection.sendDiagnostics(events)
        let sent = try #require(await socket.outgoing.last)
        var envelope = try FrameCoding.decode(sent)
        if advertisesSnapshots {
            envelope.payload = .control(.diagnostic(events: events))
            #expect(try FrameCoding.encode(envelope) == sent)
        } else {
            #expect(sent == legacyFrameBytes(id: envelope.id, timestamp: envelope.timestamp))
        }

        let onlySupplementary = events.filter {
            $0.fields[.decision] != nil || $0.fields[.phase] == .token("configure")
        }
        let count = await socket.outgoing.count
        try await connection.sendDiagnostics(onlySupplementary)
        #expect(await socket.outgoing.count == count + (advertisesSnapshots ? 1 : 0))
        await connection.disconnect()
    }

    /// Fixed canonical legacy bytes. Only the transport-generated ID and envelope time vary.
    private func legacyFrameBytes(id: UUID, timestamp: Int64) -> Data {
        let change = #"{"fields":{"reason":"category_change","route":"built_in_mic"},"name":"route_change","ts":5}"#
        let start = #"{"fields":{"route":"built_in_speaker"},"name":"reply_playback_start","ts":5}"#
        let payload = #"{"command":"diagnostic","events":[\#(change),\#(start)]}"#
        let json = #"{"id":"\#(id.uuidString)","payload":\#(payload),"source":"terminal","ts":\#(timestamp),"#
            + #""type":"control","v":1}"#
        return Data(json.utf8)
    }
}
