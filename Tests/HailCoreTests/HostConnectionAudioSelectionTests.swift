import Foundation
import HailCore
import HailProtocol
import Testing

@Suite struct HostConnectionAudioSelectionTests {
    /// Changing target mid-stream: until the host confirms the new one, no segment is tagged for either.
    @Test func reselectionInvalidatesTheConfirmedTargetBeforeAwaitingTheNewOne() async throws {
        let (connection, socket) = try await readyAudioConnection(capabilities: ["select_target", "stream_audio"])
        try await connection.sendAudio(ambientSegment())

        let reselection = Task { try await connection.selectTarget("tmux:other") }
        let select = ControlPayload.select(targetID: "tmux:other")
        try await waitUntil { try await socket.sentFrames().contains { $0.payload == .control(select) } }
        await #expect(throws: HostConnectionFailure.notReady) {
            try await connection.sendAudio(ambientSegment())
        }
        #expect(try await audioFrames(socket).count == 1)

        let frames = try await socket.sentFrames()
        guard case .control(.ping(let nonce))? = frames.last(where: {
            if case .control(.ping) = $0.payload { return true }
            return false
        })?.payload else { throw SocketTestError.unavailable }
        try await socket.push(.pong(nonce: nonce))
        try await reselection.value

        try await connection.sendAudio(ambientSegment())
        let audio = try await audioFrames(socket)
        #expect(audio.map(\.target) == [ambientTarget, "tmux:other"])
        await connection.disconnect()
    }
}
