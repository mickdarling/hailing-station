import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Host side of `stop_playback` (#309), through the real listener and loopback sockets: a stop cuts every reply
/// mid-stream on the dismissing connection and tells a device that advertised the command.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HostPlaybackStopTests {
    @Test func aCapableDeviceIsToldToStopAndTheRestOfTheReplyIsRefused() async throws {
        try await withStopRig(capabilities: [PlaybackStop.capability]) { listener, socket, connection in
            let reply = uncorrelatedDescriptor(audio: true)
            let first = recipientAudio(reply, sequence: 0)
            try #require(await listener.publish(first) == 1)
            #expect(try await recipientSocketReceive(on: socket) == first)

            #expect(await listener.stopReplyPlayback(connection: connection) == "stopped")
            #expect(try await recipientSocketReceive(on: socket).payload == .control(.stopPlayback))
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await listener.publish(recipientAudio(reply, sequence: 1, final: true))
            }
            // A later reply is not stopped.
            let next = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            try #require(await listener.publish(next) == 1)
            #expect(try await recipientSocketReceive(on: socket) == next)
        }
    }

    @Test func anOlderDeviceGetsNoStopFrameButTheReplyIsStillCut() async throws {
        try await withStopRig(capabilities: ["probe"]) { listener, socket, connection in
            let reply = uncorrelatedDescriptor(audio: true)
            let first = recipientAudio(reply, sequence: 0)
            try #require(await listener.publish(first) == 1)
            #expect(try await recipientSocketReceive(on: socket) == first)

            #expect(await listener.stopReplyPlayback(connection: connection) == "cut")
            try await recipientSocketBarrier(on: socket) // No stop frame: the next frame is the pong.
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await listener.publish(recipientAudio(reply, sequence: 1, final: true))
            }
        }
    }

    @Test func aFinishedReplyIsNotInFlightAndAnUnknownConnectionIsReported() async throws {
        try await withStopRig(capabilities: ["probe"]) { listener, socket, connection in
            let done = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            try #require(await listener.publish(done) == 1)
            #expect(try await recipientSocketReceive(on: socket) == done)
            #expect(await listener.stopReplyPlayback(connection: connection) == "idle")
            #expect(await listener.stopReplyPlayback(connection: UUID()) == "no_connection")
        }
    }

    private func withStopRig(
        capabilities: [String],
        _ body: (WebSocketListener, URLSessionWebSocketTask, UUID) async throws -> Void
    ) async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        let port = try await listener.start()
        let (session, socket) = try recipientSocket(port: port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
                versions: [1], capabilities: capabilities, deviceName: "test"
            )))), on: socket)
            _ = try await recipientSocketReceive(on: socket)
            try await recipientSocketSend(
                sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))), on: socket
            )
            try await recipientSocketBarrier(on: socket)
            let connection = try #require(await listener.onlyConnectionID())
            try await body(listener, socket, connection)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }
}

extension WebSocketListener {
    fileprivate func onlyConnectionID() async -> UUID? {
        guard peers.count == 1, let peer = peers.values.first else { return nil }
        return await peer.session.connectionID
    }
}
