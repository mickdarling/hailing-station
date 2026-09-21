import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct HostReplyDeliveryTests {
    @Test func replyReachesOnlyNegotiatedPeerSelectingItsTarget() async throws {
        var policy = Policy()
        try policy.allow("tmux:reply", binding: "binding", tier: .open)
        let (host, _) = try await sessionHost(
            targets: [AdapterTarget(name: "reply", binding: "binding")], policy: policy
        )
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-main"
        )
        let port = try await listener.start()

        do {
            let (selectedSession, selected) = try replyClient(port: port)
            let (unselectedSession, unselected) = try replyClient(port: port)
            defer {
                selected.cancel(with: .normalClosure, reason: nil)
                unselected.cancel(with: .normalClosure, reason: nil)
                selectedSession.invalidateAndCancel()
                unselectedSession.invalidateAndCancel()
            }
            try await sendReplyTestFrame(helloFrame(), on: selected)
            try await sendReplyTestFrame(helloFrame(), on: unselected)
            _ = try await receiveReplyTestFrame(on: selected)
            _ = try await receiveReplyTestFrame(on: unselected)
            try await selectReplyTarget("tmux:reply", on: selected)

            let reply = ReplyDescriptor(id: UUID(), hostID: "mac-main", targetID: "tmux:reply")
            let frame = Frame(
                timestamp: 1_700_000_000_100, target: reply.targetID, source: reply.hostID,
                payload: .text(TextPayload(text: "ready", reply: reply))
            )
            try #require(await listener.publish(frame) == 1)
            #expect(try await receiveReplyTestFrame(on: selected) == frame)
        } catch {
            await listener.stop(reason: "test failed")
            throw error
        }
        await listener.stop(reason: "test complete")
    }

    @Test func publicationRejectsCrossAssociatedProvenance() async throws {
        let (host, _) = try await sessionHost()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host)
        _ = try await listener.start()
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac-main", targetID: "tmux:reply")
        let mismatched = Frame(
            timestamp: 1, target: "tmux:other", source: reply.hostID,
            payload: .text(TextPayload(text: "wrong target", reply: reply))
        )
        await #expect(throws: WebSocketListenerError.invalidReply) {
            try await listener.publish(mismatched)
        }
        await listener.stop(reason: "test complete")
    }

    @Test func publicationRejectsAnotherHostsIdentity() async throws {
        let (host, _) = try await sessionHost()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host, hostName: "mac-main"
        )
        _ = try await listener.start()
        let reply = ReplyDescriptor(id: UUID(), hostID: "ziggy", targetID: "tmux:reply")
        let impersonating = Frame(
            timestamp: 1, target: reply.targetID, source: reply.hostID,
            payload: .text(TextPayload(text: "wrong host", reply: reply))
        )
        await #expect(throws: WebSocketListenerError.invalidReply) {
            try await listener.publish(impersonating)
        }
        await listener.stop(reason: "test complete")
    }

    // The setup and four transition assertions intentionally stay together as one stream-lifecycle scenario.
    // swiftlint:disable:next function_body_length
    @Test func audioStreamKeepsItsOriginalRecipientsUntilFinal() async throws {
        var policy = Policy()
        try policy.allow("tmux:reply", binding: "reply-binding", tier: .open)
        try policy.allow("tmux:other", binding: "other-binding", tier: .open)
        let (host, _) = try await sessionHost(
            targets: [
                AdapterTarget(name: "reply", binding: "reply-binding"),
                AdapterTarget(name: "other", binding: "other-binding")
            ],
            policy: policy
        )
        let original = HostSession(
            host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-main"
        )
        let late = HostSession(
            host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-main"
        )
        _ = await original.receive(helloFrame())
        _ = await late.receive(helloFrame())
        _ = await original.receive(sessionFrame(payload: .control(.select(targetID: "tmux:reply"))))

        let descriptor = ReplyDescriptor(
            id: UUID(), hostID: "mac-main", targetID: "tmux:reply", audioStreamID: UUID()
        )
        let streamID = try #require(descriptor.audioStreamID)
        #expect(await original.acceptsHostReply(audioReply(
            descriptor: descriptor, streamID: streamID, sequence: 0
        )))
        #expect(!(await late.acceptsHostReply(audioReply(
            descriptor: descriptor, streamID: streamID, sequence: 0
        ))))

        _ = await late.receive(sessionFrame(payload: .control(.select(targetID: "tmux:reply"))))
        _ = await original.receive(sessionFrame(payload: .control(.select(targetID: "tmux:other"))))
        #expect(await original.acceptsHostReply(audioReply(
            descriptor: descriptor, streamID: streamID, sequence: 1
        )))
        #expect(!(await late.acceptsHostReply(audioReply(
            descriptor: descriptor, streamID: streamID, sequence: 1
        ))))

        #expect(await original.acceptsHostReply(audioReply(
            descriptor: descriptor, streamID: streamID, sequence: 2, isFinal: true
        )))
        #expect(!(await original.acceptsHostReply(audioReply(
            descriptor: descriptor, streamID: streamID, sequence: 3
        ))))
    }
}

private func audioReply(
    descriptor: ReplyDescriptor, streamID: UUID, sequence: Int, isFinal: Bool = false
) -> Frame {
    Frame(
        timestamp: 1_700_000_000_100, target: descriptor.targetID, source: descriptor.hostID,
        payload: .audio(AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
            streamID: streamID, isFinal: isFinal, bytes: Data([0, 0]), reply: descriptor
        ))
    )
}

private func replyClient(port: UInt16) throws -> (URLSession, URLSessionWebSocketTask) {
    let session = URLSession(configuration: .ephemeral)
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
    let socket = session.webSocketTask(with: url, protocols: [WebSocketListener.subprotocolName])
    socket.resume()
    return (session, socket)
}

private func sendReplyTestFrame(_ frame: Frame, on socket: URLSessionWebSocketTask) async throws {
    let data = try FrameCoding.encode(frame)
    try await socket.send(.data(data))
}

private func selectReplyTarget(_ targetID: String, on socket: URLSessionWebSocketTask) async throws {
    try await sendReplyTestFrame(
        sessionFrame(payload: .control(.select(targetID: targetID))), on: socket
    )
    let nonce = "selection-applied"
    try await sendReplyTestFrame(
        sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket
    )
    try #require(await receiveReplyTestFrame(on: socket).payload == .control(.pong(nonce: nonce)))
}

private func receiveReplyTestFrame(on socket: URLSessionWebSocketTask) async throws -> Frame {
    switch try await socket.receive() {
    case .data(let data): try FrameCoding.decode(data)
    case .string(let string): try FrameCoding.decode(Data(string.utf8))
    @unknown default: throw TestSupportError.expectedOneControl
    }
}
