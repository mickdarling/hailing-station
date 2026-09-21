import Foundation
import HailCore
import HailProtocol
import Testing

@Suite struct HostConnectionProtocolTests {
    @Test func helloPingPongAndTargetListingReachReady() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(endpoint: endpoint, connector: connector, jitter: { 0.5 })

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await socket.push(hostHello())
        try await waitUntil { try await socket.sentFrames().count == 3 }

        let sent = try await socket.sentFrames()
        guard case .control(.hello) = sent[0].payload,
              case .control(.ping(let nonce)) = sent[1].payload,
              case .control(.listTargets) = sent[2].payload else {
            Issue.record("expected hello, ping, and list_targets")
            return
        }
        let targets = [TargetInfo(id: "tmux:one", kind: "tmux", name: "one", alive: true)]
        try await socket.push(.pong(nonce: nonce))
        try await socket.push(.targets(targets))
        try await waitUntil { await connection.currentSnapshot().targets == targets }

        let snapshot = await connection.currentSnapshot()
        #expect(snapshot.state == .ready)
        #expect(snapshot.negotiatedVersion == ProtocolVersion.current)
        #expect(snapshot.capabilities == ["connection_probe", "ping"])
        #expect(snapshot.lastPingMilliseconds != nil)
        #expect(snapshot.receivedTargetList)
        await connection.disconnect()
        let disconnected = await connection.currentSnapshot()
        #expect(disconnected.lastPingMilliseconds == nil)
        #expect(disconnected.targets.isEmpty)
        #expect(!disconnected.receivedTargetList)
    }

    @Test func malformedAndIncompatibleHelloFailClosed() async throws {
        for input in [Data("not-json".utf8), try incompatibleHello()] {
            let endpoint = try endpoint(UUID().uuidString)
            let socket = ScriptedSocket()
            let connector = ScriptedConnector()
            await connector.enqueue(.socket(socket), for: endpoint.url)
            let connection = HostConnection(endpoint: endpoint, connector: connector)
            await connection.connect()
            try await waitUntil { await connection.currentSnapshot().state == .negotiating }
            try await socket.push(input)
            try await waitUntil {
                if case .failed = await connection.currentSnapshot().state { return true }
                return false
            }
            #expect(await socket.closeCount == 1)
        }
    }

    @Test func readyTerminalSelectsSendsFinalTextAndEscapes() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(endpoint: endpoint, connector: connector, deviceName: "Mick's iPad")

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current],
            capabilities: ["select_target", "send_text", "escape"], deviceName: "Mac"
        )))
        try await waitUntil { await connection.currentSnapshot().state == .ready }

        try await connection.selectTarget("tmux:codex")
        try await connection.sendFinalText("run the tests", to: "tmux:codex")
        try await connection.sendEscape(to: "tmux:codex")

        let frames = try await socket.sentFrames()
        #expect(frames.contains { $0.payload == .control(.select(targetID: "tmux:codex")) })
        #expect(frames.contains {
            $0.target == "tmux:codex" && $0.source == "Mick's iPad"
                && $0.payload == .text(TextPayload(text: "run the tests", isFinal: true))
        })
        #expect(frames.contains { $0.payload == .control(.escape(targetID: "tmux:codex")) })
        await connection.disconnect()
    }

    @Test func terminalActionsRequireReadyAdvertisedCapabilities() async throws {
        let connection = HostConnection(endpoint: try endpoint())
        await #expect(throws: HostConnectionFailure.notReady) {
            try await connection.sendFinalText("hello", to: "tmux:a")
        }
    }

    private func incompatibleHello() throws -> Data {
        let frame = Frame(
            version: 99, timestamp: 1, source: "haild",
            payload: .control(.hello(HelloInfo(versions: [99], capabilities: [], deviceName: "future")))
        )
        return try FrameCoding.encode(frame)
    }
}
