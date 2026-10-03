import Foundation
import HailCore
import HailProtocol
import Testing

@Suite struct HostConnectionAudioTests {
    private func readyConnection(
        capabilities: [String]
    ) async throws -> (HostConnection, ScriptedSocket) {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(endpoint: endpoint, connector: connector, deviceName: "iPad")
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: capabilities, deviceName: "Mac"
        )))
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        return (connection, socket)
    }

    private func segment(sequence: Int = 0, isFinal: Bool = false) -> AudioPayload {
        AudioPayload(
            codec: .pcm16, sampleRate: 16_000, channels: 1, sequence: sequence,
            streamID: UUID(), isFinal: isFinal, bytes: Data(count: 3_200)
        )
    }

    private func audioFrames(_ socket: ScriptedSocket) async throws -> [AudioPayload] {
        try await socket.sentFrames().compactMap {
            if case .audio(let audio) = $0.payload { return audio }
            return nil
        }
    }

    @Test func sendsAudioOnlyWhenTheHostAdvertisesStreamAudio() async throws {
        let (connection, socket) = try await readyConnection(capabilities: ["send_text"])
        await #expect(throws: HostConnectionFailure.unsupportedCapability("stream_audio")) {
            try await connection.sendAudio(segment())
        }
        #expect(try await audioFrames(socket).isEmpty)
        await connection.disconnect()
    }

    @Test func sendsTheExistingAudioFrameWhenAdvertised() async throws {
        let (connection, socket) = try await readyConnection(capabilities: ["stream_audio"])
        let payload = segment(sequence: 3, isFinal: true)
        try await connection.sendAudio(payload)

        let frames = try await socket.sentFrames().filter {
            if case .audio = $0.payload { return true }
            return false
        }
        #expect(frames.count == 1)
        #expect(frames.first?.target == nil)
        #expect(frames.first?.source == "iPad")
        #expect(try await audioFrames(socket) == [payload])
        await connection.disconnect()
    }

    @Test func refusesAudioBeforeReadyAndReplyShapedSegments() async throws {
        let idle = HostConnection(endpoint: try endpoint())
        await #expect(throws: HostConnectionFailure.notReady) { try await idle.sendAudio(segment()) }

        let (connection, socket) = try await readyConnection(capabilities: ["stream_audio"])
        var unidentified = segment()
        unidentified.streamID = nil
        await #expect(throws: HostConnectionFailure.malformed("ambient audio segment is malformed")) {
            try await connection.sendAudio(unidentified)
        }
        #expect(try await audioFrames(socket).isEmpty)
        await connection.disconnect()
    }

    @MainActor
    @Test func storeRefusesAudioForAnUnknownHost() async throws {
        let store = HostConnectionStore(connector: ScriptedConnector())
        await #expect(throws: HostConnectionFailure.notReady) {
            try await store.sendAudio(segment(), host: try endpoint().id)
        }
    }
}
