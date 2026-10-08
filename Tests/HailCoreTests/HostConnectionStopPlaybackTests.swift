import Foundation
import HailCore
import HailProtocol
import Testing

/// The device side of `stop_playback` (#309): it is advertised in the hello and handed to the reply player.
@Suite struct HostConnectionStopPlaybackTests {
    @Test func theHelloAdvertisesStopPlaybackAndTheStopReachesTheReplyPlayer() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        let replies = StopEvents()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint, connector: connector, replyObserver: { await replies.append($0) }
        )
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        let hello = try await socket.sentFrames().first?.payload
        guard case .control(.hello(let info)) = hello else {
            Issue.record("expected the device hello first")
            return
        }
        #expect(info.capabilities.contains(PlaybackStop.capability))

        // No reply capability is needed to be told to stop.
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: [], deviceName: "Mac"
        )))
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        let stop = Frame(timestamp: 1, source: "host", payload: .control(.stopPlayback))
        try await socket.push(FrameCoding.encode(stop))
        try await waitUntil { await replies.values.count == 1 }

        #expect(await replies.values == [HostReplyEvent(endpointID: endpoint.id, frame: stop)])
        #expect(await connection.currentSnapshot().state == .ready)
        await connection.disconnect()
    }
}

private actor StopEvents {
    private(set) var values: [HostReplyEvent] = []
    func append(_ event: HostReplyEvent) { values.append(event) }
}
