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
            try await sendReplyTestFrame(
                sessionFrame(payload: .control(.select(targetID: "tmux:reply"))), on: selected
            )

            let reply = ReplyDescriptor(id: UUID(), hostID: "mac-main", targetID: "tmux:reply")
            let frame = Frame(
                timestamp: 1_700_000_000_100, target: reply.targetID, source: reply.hostID,
                payload: .text(TextPayload(text: "ready", reply: reply))
            )
            #expect(try await listener.publish(frame) == 1)
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

private func receiveReplyTestFrame(on socket: URLSessionWebSocketTask) async throws -> Frame {
    switch try await socket.receive() {
    case .data(let data): try FrameCoding.decode(data)
    case .string(let string): try FrameCoding.decode(Data(string.utf8))
    @unknown default: throw TestSupportError.expectedOneControl
    }
}
