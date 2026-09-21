import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct LocalReplyEndpointTests {
    // The full socket-to-terminal proof deliberately keeps setup, assertion, and teardown in one scope.
    // swiftlint:disable:next function_body_length
    @Test func privateLocalSubmissionReachesSelectedTerminalAndIsAudited() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
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
        let config = scratch.appendingPathComponent("config", isDirectory: true)
        let socket = config.appendingPathComponent(LocalReplyEndpoint.socketName)
        let auditDirectory = config.appendingPathComponent("audit", isDirectory: true)
        let audit = AuditLog(directory: auditDirectory)
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: listener, audit: audit)
        try await endpoint.start()

        let (session, terminal) = try terminalClient(port: port)
        defer {
            terminal.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            try await terminal.send(.data(FrameCoding.encode(helloFrame())))
            _ = try await terminal.receive()
            try await terminal.send(.data(FrameCoding.encode(
                sessionFrame(payload: .control(.select(targetID: "tmux:reply")))
            )))
            let reply = ReplyDescriptor(id: UUID(), hostID: "mac-main", targetID: "tmux:reply")
            let frame = Frame(
                timestamp: 1, target: reply.targetID, source: reply.hostID,
                payload: .text(TextPayload(text: "ready", reply: reply))
            )
            #expect(try await LocalReplyClient.submit(frame, socketURL: socket) == 1)
            #expect(try await terminalFrame(terminal) == frame)
            var info = stat()
            try #require(lstat(socket.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(try AuditHistory(directory: auditDirectory).today().last?.contains("\"kind\":\"pushed\"") == true)
        } catch {
            await endpoint.stop()
            await listener.stop(reason: "test failed")
            throw error
        }
        await endpoint.stop()
        await listener.stop(reason: "test complete")
        #expect(!FileManager.default.fileExists(atPath: socket.path))
    }
}

private func terminalClient(port: UInt16) throws -> (URLSession, URLSessionWebSocketTask) {
    let session = URLSession(configuration: .ephemeral)
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
    let socket = session.webSocketTask(with: url, protocols: [WebSocketListener.subprotocolName])
    socket.resume()
    return (session, socket)
}

private func terminalFrame(_ socket: URLSessionWebSocketTask) async throws -> Frame {
    switch try await socket.receive() {
    case .data(let data): try FrameCoding.decode(data)
    case .string(let text): try FrameCoding.decode(Data(text.utf8))
    @unknown default: throw TestSupportError.expectedOneControl
    }
}
