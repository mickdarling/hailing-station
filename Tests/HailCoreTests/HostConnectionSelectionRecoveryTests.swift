import HailCore
import HailProtocol
import Testing

@Suite struct HostConnectionSelectionRecoveryTests {
    @Test func confirmedSelectionIsReplayedOnTheReplacementConnection() async throws {
        let endpoint = try endpoint()
        let first = ScriptedSocket()
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(first), for: endpoint.url)
        await connector.enqueue(.socket(replacement), for: endpoint.url)
        let connection = HostConnection(endpoint: endpoint, connector: connector)
        let hello = HelloInfo(
            versions: [ProtocolVersion.current],
            capabilities: ["select_target", "ping"], deviceName: "Mac"
        )

        await connection.connect()
        try await waitUntil { try await first.sentFrames().count == 1 }
        try await first.push(.hello(hello))
        try await waitUntil { await connection.currentSnapshot().state == .ready }

        let selection = Task { try await connection.selectTarget("tmux:codex") }
        try await waitUntil { try await first.sentFrames().count >= 5 }
        let firstFrames = try await first.sentFrames()
        guard case .control(.ping(let nonce)) = firstFrames[4].payload else {
            Issue.record("selection was not followed by a confirmation ping")
            return
        }
        try await first.push(.pong(nonce: nonce))
        try await selection.value

        await connection.disconnect()
        await connection.connect()
        try await waitUntil { try await replacement.sentFrames().count == 1 }
        try await replacement.push(.hello(hello))
        try await waitUntil {
            try await replacement.sentFrames().contains {
                $0.payload == .control(.select(targetID: "tmux:codex"))
            }
        }

        await connection.disconnect()
    }
}
