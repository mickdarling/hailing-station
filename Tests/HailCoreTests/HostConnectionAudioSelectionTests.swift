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

    /// Overlapping selections: an earlier call's confirmation must not settle a later, failed one.
    @Test func onlyTheLatestSelectionSettlesAndItsFailureKeepsAudioRefused() async throws {
        let (connection, socket) = try await readyAudioConnection(capabilities: ["select_target", "stream_audio"])
        let earlier = Task { try await connection.selectTarget("tmux:b") }
        let earlierNonce = try await nextPing(on: socket, after: "tmux:b")
        let later = Task { try await connection.selectTarget("tmux:c") }
        _ = try await nextPing(on: socket, after: "tmux:c")

        try await socket.push(.pong(nonce: earlierNonce))
        try await earlier.value
        await #expect(throws: HostConnectionFailure.notReady) { try await connection.sendAudio(ambientSegment()) }

        later.cancel()
        _ = await later.result
        await #expect(throws: HostConnectionFailure.notReady) { try await connection.sendAudio(ambientSegment()) }
        #expect(try await audioFrames(socket).isEmpty)

        let settled = Task { try await connection.selectTarget("tmux:d") }
        try await socket.push(.pong(nonce: try await nextPing(on: socket, after: "tmux:d")))
        try await settled.value
        try await connection.sendAudio(ambientSegment())
        #expect(try await audioFrames(socket).map(\.target) == ["tmux:d"])
        await connection.disconnect()
    }

    private func nextPing(on socket: ScriptedSocket, after target: String) async throws -> String {
        let select = ControlPayload.select(targetID: target)
        try await waitUntil {
            let frames = try await socket.sentFrames()
            guard let index = frames.lastIndex(where: { $0.payload == .control(select) }) else { return false }
            return frames[index...].contains { if case .control(.ping) = $0.payload { return true }; return false }
        }
        let frames = try await socket.sentFrames()
        let index = try #require(frames.lastIndex { $0.payload == .control(select) })
        for frame in frames[index...] {
            if case .control(.ping(let nonce)) = frame.payload { return nonce }
        }
        throw SocketTestError.unavailable
    }
}
