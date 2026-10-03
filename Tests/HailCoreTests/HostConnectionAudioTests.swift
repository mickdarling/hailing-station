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
    // Pong deadlines are not under test here. Ending them at once keeps no five-second sleeper alive past the
    // test, where its task teardown aborted the parallel test helper (signal 6 in schedulePongDeadline).
    let connection = HostConnection(
        endpoint: endpoint, connector: connector, deviceName: "iPad",
        deadlineSleep: { _ in throw CancellationError() }
    )
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
            try await connection.sendAudio(ambientSegment(stream: stream, sequence: 1, bytes: 8 * 1_024 + 2))
        }
        // The gate (#205) ends the whole stream on these, so they are refused before sending.
        for bytes in [0, 3_199] {
            await #expect(throws: HostConnectionFailure.malformed("ambient audio segment is malformed")) {
                try await connection.sendAudio(ambientSegment(stream: stream, sequence: 1, bytes: bytes))
            }
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
        let (connection, second) = try await reconnectedAfterStreaming()
        let stream = UUID()
        await #expect(throws: HostConnectionFailure.notReady) {
            try await connection.sendAudio(ambientSegment(stream: firstStream, sequence: 1))
        }
        let next = Task { try await connection.sendAudio(ambientSegment(stream: stream)) }
        try await answerSelectionConfirmation(on: second)
        try await next.value
        let frames = try await audioFrames(second)
        #expect(frames.count == 1)
        #expect(frames.first?.target == ambientTarget)
        await connection.disconnect()
    }

    /// After a reconnect the restored selection is sent but unacknowledged; audio must wait for a confirmed one.
    @Test func audioWaitsForTheSelectionToBeConfirmedAfterAReconnect() async throws {
        let (connection, second) = try await reconnectedAfterStreaming()
        let send = Task { try await connection.sendAudio(ambientSegment()) }
        let select = ControlPayload.select(targetID: ambientTarget)
        try await waitUntil { try await second.sentFrames().count { $0.payload == .control(select) } == 2 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(try await audioFrames(second).isEmpty)

        try await answerSelectionConfirmation(on: second)
        try await send.value
        let frames = try await second.sentFrames()
        let lastSelect = try #require(frames.lastIndex { $0.payload == .control(.select(targetID: ambientTarget)) })
        let audio = try #require(frames.firstIndex { if case .audio = $0.payload { return true }; return false })
        #expect(audio > lastSelect)

        // Confirmed once per connection: the next segment goes straight out.
        try await connection.sendAudio(ambientSegment())
        #expect(try await audioFrames(second).count == 2)
        await connection.disconnect()
    }

    private let firstStream = UUID()

    private func reconnectedAfterStreaming() async throws -> (HostConnection, ScriptedSocket) {
        let first = ScriptedSocket()
        let second = ScriptedSocket()
        let (connection, _) = try await readyAudioConnection(
            capabilities: ["select_target", "stream_audio"], sockets: [first, second]
        )
        try await connection.sendAudio(ambientSegment(stream: firstStream))
        await connection.disconnect()
        await connection.connect()
        try await awaitHello(connection, second, capabilities: ["select_target", "stream_audio"])
        return (connection, second)
    }

    private func answerSelectionConfirmation(on socket: ScriptedSocket) async throws {
        try await waitUntil {
            let frames = try await socket.sentFrames()
            guard let select = frames.lastIndex(where: { $0.payload == .control(.select(targetID: ambientTarget)) })
            else { return false }
            return frames[select...].contains { if case .control(.ping) = $0.payload { return true }; return false }
        }
        let frames = try await socket.sentFrames()
        guard case .control(.ping(let nonce))? = frames.last(where: {
            if case .control(.ping) = $0.payload { return true }
            return false
        })?.payload else { throw SocketTestError.unavailable }
        try await socket.push(.pong(nonce: nonce))
    }
}
