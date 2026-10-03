import Foundation
import HailCore
import HailProtocol
import Testing

let ambientTarget = "tmux:ambient"

/// A ready connection whose host advertised `capabilities`; with `select`, the ambient target is confirmed.
func readyAudioConnection(
    capabilities: [String], select: Bool = true, sockets: [ScriptedSocket] = [ScriptedSocket()]
) async throws -> (HostConnection, ScriptedSocket) {
    let endpoint = try endpoint()
    let connector = ScriptedConnector()
    for socket in sockets { await connector.enqueue(.socket(socket), for: endpoint.url) }
    let socket = sockets[0]
    let connection = HostConnection(endpoint: endpoint, connector: connector, deviceName: "iPad")
    await connection.connect()
    try await awaitHello(connection, socket, capabilities: capabilities)
    guard select else { return (connection, socket) }
    let selection = Task { try await connection.selectTarget(ambientTarget) }
    try await waitUntil { try await socket.sentFrames().count >= 5 }
    guard case .control(.ping(let nonce)) = try await socket.sentFrames()[4].payload else {
        throw SocketTestError.unavailable
    }
    try await socket.push(.pong(nonce: nonce))
    try await selection.value
    return (connection, socket)
}

func awaitHello(_ connection: HostConnection, _ socket: ScriptedSocket, capabilities: [String]) async throws {
    try await waitUntil { await connection.currentSnapshot().state == .negotiating }
    try await socket.push(.hello(HelloInfo(
        versions: [ProtocolVersion.current], capabilities: capabilities, deviceName: "Mac"
    )))
    try await waitUntil { await connection.currentSnapshot().state == .ready }
}

func ambientSegment(stream: UUID = UUID(), sequence: Int = 0, bytes: Int = 3_200) -> AudioPayload {
    AudioPayload(
        codec: .pcm16, sampleRate: 16_000, channels: 1, sequence: sequence,
        streamID: stream, isFinal: false, bytes: Data(count: bytes)
    )
}

func audioFrames(_ socket: ScriptedSocket) async throws -> [Frame] {
    try await socket.sentFrames().filter {
        if case .audio = $0.payload { return true }
        return false
    }
}

@Suite struct HostConnectionAudioTests {
    @Test func sendsAudioOnlyWhenTheHostAdvertisesStreamAudio() async throws {
        let (connection, socket) = try await readyAudioConnection(capabilities: ["select_target"])
        await #expect(throws: HostConnectionFailure.unsupportedCapability("stream_audio")) {
            try await connection.sendAudio(ambientSegment())
        }
        #expect(try await audioFrames(socket).isEmpty)
        await connection.disconnect()
    }

    @Test func refusesAudioBeforeReadyOrWithoutASelectedDestination() async throws {
        let idle = HostConnection(endpoint: try endpoint())
        await #expect(throws: HostConnectionFailure.notReady) { try await idle.sendAudio(ambientSegment()) }

        let (connection, socket) = try await readyAudioConnection(capabilities: ["stream_audio"], select: false)
        await #expect(throws: HostConnectionFailure.notReady) { try await connection.sendAudio(ambientSegment()) }
        #expect(try await audioFrames(socket).isEmpty)
        await connection.disconnect()
    }

    /// The host gate (#205) admits a segment only when the frame names the session's selected ambient target.
    @Test func addressesTheExistingAudioFrameToTheSelectedDestination() async throws {
        let (connection, socket) = try await readyAudioConnection(capabilities: ["select_target", "stream_audio"])
        let payload = ambientSegment()
        try await connection.sendAudio(payload)

        let frames = try await audioFrames(socket)
        #expect(frames.count == 1)
        #expect(frames.first?.target == ambientTarget)
        #expect(frames.first?.source == "iPad")
        #expect(frames.first?.payload == .audio(payload))
        await connection.disconnect()
    }

    @Test func capsSegmentsAtTheGatesEightKilobytes() async throws {
        let (connection, socket) = try await readyAudioConnection(capabilities: ["select_target", "stream_audio"])
        let stream = UUID()
        try await connection.sendAudio(ambientSegment(stream: stream, bytes: 8 * 1_024))
        await #expect(throws: HostConnectionFailure.malformed("ambient audio segment is malformed")) {
            try await connection.sendAudio(ambientSegment(stream: stream, sequence: 1, bytes: 8 * 1_024 + 1))
        }
        var unidentified = ambientSegment()
        unidentified.streamID = nil
        await #expect(throws: HostConnectionFailure.malformed("ambient audio segment is malformed")) {
            try await connection.sendAudio(unidentified)
        }
        #expect(try await audioFrames(socket).count == 1)
        await connection.disconnect()
    }

    @Test func anAmbientRefusalEndsOnlyThatStreamAndKeepsTheConnection() async throws {
        let (connection, socket) = try await readyAudioConnection(capabilities: ["select_target", "stream_audio"])
        let refused = UUID()
        try await connection.sendAudio(ambientSegment(stream: refused))
        try await socket.push(.error(code: .notAllowed, message: "ambient busy"))
        try await socket.push(.pong(nonce: "after-refusal"))
        try await Task.sleep(for: .milliseconds(50))

        #expect(await connection.currentSnapshot().state == .ready)
        await #expect(throws: HostConnectionFailure.remote("not_allowed: ambient busy")) {
            try await connection.sendAudio(ambientSegment(stream: refused, sequence: 1))
        }
        try await connection.sendAudio(ambientSegment())
        #expect(try await audioFrames(socket).count == 2)
        await connection.disconnect()
    }

    @Test func aStreamIsBoundToTheConnectionItStartedOn() async throws {
        let first = ScriptedSocket()
        let second = ScriptedSocket()
        let (connection, _) = try await readyAudioConnection(
            capabilities: ["select_target", "stream_audio"], sockets: [first, second]
        )
        let stream = UUID()
        try await connection.sendAudio(ambientSegment(stream: stream))

        await connection.disconnect()
        await connection.connect()
        try await awaitHello(connection, second, capabilities: ["select_target", "stream_audio"])
        await #expect(throws: HostConnectionFailure.notReady) {
            try await connection.sendAudio(ambientSegment(stream: stream, sequence: 1))
        }
        try await connection.sendAudio(ambientSegment())
        let frames = try await audioFrames(second)
        #expect(frames.count == 1)
        #expect(frames.first?.target == ambientTarget)
        await connection.disconnect()
    }
}
