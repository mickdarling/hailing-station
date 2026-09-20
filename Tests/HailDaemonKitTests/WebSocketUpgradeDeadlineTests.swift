import Foundation
import Network
import Testing
@testable import HailDaemonKit

@Suite struct WebSocketUpgradeDeadlineTests {
    @Test func stalledUpgradeExpiresBeforeWebSocketReadiness() async throws {
        let (host, _) = try await sessionHost()
        let events = UpgradeEventLog()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host,
            maxConnections: 1, helloTimeout: .milliseconds(100)
        ) { event in
            Task { await events.record(event) }
        }
        let port = try await listener.start()
        let endpointPort = try #require(NWEndpoint.Port(rawValue: port))
        let stalledTCP = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        stalledTCP.start(queue: .global(qos: .utility))
        defer { stalledTCP.cancel() }

        let expired = await events.waitForDisconnect()
        let observed = await events.snapshot()
        #expect(expired, "observed events: \(observed)")
        await listener.stop(reason: "test complete")
    }
}

private actor UpgradeEventLog {
    private var events: [WebSocketListenerEvent] = []

    func record(_ event: WebSocketListenerEvent) { events.append(event) }
    func snapshot() -> [WebSocketListenerEvent] { events }

    func waitForDisconnect() async -> Bool {
        for _ in 0..<100 {
            if events.contains(where: {
                $0.event == "session_disconnected" && $0.detail == "hello timeout"
            }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
