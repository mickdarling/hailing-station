import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Real loopback WebSocket frames; no provider, microphone, installed app or physical device.
@Suite(.serialized, .timeLimit(.minutes(1))) struct SilentSessionUpdateWireTests {
    @Test func silentCardArrivesBetweenReplyAudioFramesWithoutChangingTheReply() async throws {
        let host = try await RecipientTestRig.make()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host.host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        await listener.enableSessionUpdates()
        let port = try await listener.start()
        do { try await exercise(listener, port: port) } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
    }

    private func exercise(_ listener: WebSocketListener, port: UInt16) async throws {
        let (client, socket) = try recipientSocket(port: port)
        defer { socket.cancel(with: .normalClosure, reason: nil); client.invalidateAndCancel() }
        try await recipientSocketSend(helloFrame(capabilities: [SessionUpdateCard.capability]), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await recipientSocketBarrier(on: socket)
        let peer = try #require(await listener.silentWireRecipient())
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                    audioStreamID: UUID())
        let frames = [recipientText(reply), recipientAudio(reply, sequence: 0),
                      recipientAudio(reply, sequence: 1, final: true)]
        for frame in frames.prefix(2) {
            let prepared = try #require(await peer.prepareReplyPublication(frame))
            #expect(prepared.enqueue())
            #expect(await prepared.result() == .sent)
            #expect(try await recipientSocketReceive(on: socket) == frame)
        }
        let report = await listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
            text: "Synthetic silent card", card: "Synthetic visual content"))
        #expect(report.outcome == .delivered && report.held == 0)
        // A pong bounds a missing card without a receive timeout, including in the waiting mutation.
        let nonce = UUID().uuidString
        try await recipientSocketSend(sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket)
        let middle = try await recipientSocketReceive(on: socket)
        if case .control(.sessionUpdate) = middle.payload {
            #expect(middle.target == RecipientTestRig.target)
            #expect(try await recipientSocketReceive(on: socket).payload == .control(.pong(nonce: nonce)))
        } else { Issue.record("silent card must arrive between sequence 0 and the terminal, before the pong") }
        let terminal = try #require(await peer.prepareReplyPublication(frames[2]))
        #expect(terminal.enqueue())
        #expect(await terminal.result() == .sent)
        #expect(try await recipientSocketReceive(on: socket) == frames[2])
        await listener.drainSilentSessionUpdates(.immediate)
        try await recipientSocketBarrier(on: socket, step: "no duplicate card after reply terminal")
    }
}

extension WebSocketListener {
    func silentWireRecipient() async -> WebSocketPeer? {
        guard let peer = peers.values.first else { return nil }
        let session = await peer.session
        let connection = await session.connectionID, generation = await session.selectionGeneration
        lastInput.record(.init(connection: connection, generation: generation, at: .now),
                         for: RecipientTestRig.target)
        return peer
    }
}
