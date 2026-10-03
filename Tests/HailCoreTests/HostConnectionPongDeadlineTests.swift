import Foundation
import HailCore
import HailProtocol
import Testing

/// Regression for the signal-6 abort in #206: with the default sleeps, many pong deadlines waking in parallel
/// aborted the test helper in `swift_task_dealloc` ("freed pointer was not the last allocation").
@Suite struct HostConnectionPongDeadlineTests {
    @Test(arguments: 0..<40) func defaultPongDeadlinesWakeWithoutCorruptingTheTaskAllocator(index: Int) async throws {
        let endpoint = try endpoint("stress-\(index)")
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint, connector: connector, pongTimeout: .milliseconds(5)
        )
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: [], deviceName: "Mac"
        )))
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        for _ in 0..<20 { await connection.foregrounded() }
        if index % 2 == 0 { await connection.disconnect() }
        try await Task.sleep(for: .milliseconds(20))
    }
}
