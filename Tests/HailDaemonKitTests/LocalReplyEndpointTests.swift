import Foundation
import HailProtocol
import Network
import Testing
@testable import HailDaemonKit

// Socket security, deadline, and full delivery proofs intentionally share their integration helpers.
// swiftlint:disable file_length

// The serialized suite owns one endpoint at a time and deliberately shares its socket test harness.
// swiftlint:disable:next type_body_length
@Suite(.serialized) struct LocalReplyEndpointTests {
    @Test func refusesSocketBelowOtherWritableAncestor() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-unsafe-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        #expect(chmod(scratch.path, 0o777) == 0)
        let listener = try await testListener()
        let socket = scratch.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        #expect(throws: LocalReplyEndpointError.self) {
            _ = try LocalReplyEndpoint(
                socketURL: socket, destination: listener,
                audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
            )
        }
    }

    @Test func resolvesSymlinkBeforeCheckingSocketAncestors() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-link-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let unsafe = scratch.appendingPathComponent("unsafe", isDirectory: true)
        let victim = unsafe.appendingPathComponent("victim", isDirectory: true)
        let safe = scratch.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(
            at: victim.appendingPathComponent("config"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        #expect(chmod(unsafe.path, 0o777) == 0)
        try FileManager.default.createSymbolicLink(
            at: safe.appendingPathComponent("link"), withDestinationURL: victim
        )
        let listener = try await testListener()
        let socket = safe.appendingPathComponent("link/config/\(LocalReplyEndpoint.socketName)")
        var refused = false
        do {
            _ = try LocalReplyEndpoint(
                socketURL: socket, destination: listener,
                audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
            )
        } catch {
            refused = true
        }
        #expect(refused)
    }

    @Test func refusesWritableACLAncestor() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-acl-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow add_file", scratch.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        let listener = try await testListener()
        let socket = scratch.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        #expect(throws: LocalReplyEndpointError.self) {
            _ = try LocalReplyEndpoint(
                socketURL: socket, destination: listener,
                audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
            )
        }
    }

    @Test func incompleteConnectionExpires() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-timeout-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let listener = try await testListener()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")),
            requestTimeout: .milliseconds(50)
        )
        try await endpoint.start()
        let idle = NWConnection(to: .unix(path: socket.path), using: .tcp)
        idle.start(queue: DispatchQueue(label: "hail.local-reply-idle-test"))
        try await waitUntil { await endpoint.activeConnectionCount == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await endpoint.activeConnectionCount == 0)
        idle.cancel()
        await endpoint.stop()
    }

    @Test func completedFrameDisarmsRequestDeadline() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-complete-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let listener = try await testListener()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")),
            requestTimeout: .milliseconds(50)
        )
        try await endpoint.start()
        let client = NWConnection(to: .unix(path: socket.path), using: .tcp)
        client.start(queue: DispatchQueue(label: "hail.local-reply-complete-test"))
        try await waitUntil { await endpoint.activeConnectionCount == 1 }
        let id = try #require(await endpoint.awaitingFrameIDs.first)
        await endpoint.frameCompleted(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await endpoint.activeConnectionCount == 1)
        client.cancel()
        await endpoint.stop()
    }

    @Test func submissionDeadlineCancelsBlockedPublish() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hpt-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let publisher = BlockingReplyPublisher()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: publisher,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")),
            submissionTimeout: .milliseconds(50)
        )
        try await endpoint.start()
        let client = try sendWithoutResponse(replyFrame(), socket: socket.path)
        try await waitUntil { await publisher.started }
        try await waitUntil { await publisher.cancelled }
        #expect(await endpoint.activeConnectionCount == 0)
        client.cancel()
        await endpoint.stop()
    }

    @Test func stopCancelsBlockedPublish() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hps-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let publisher = BlockingReplyPublisher()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: publisher,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
        )
        try await endpoint.start()
        let client = try sendWithoutResponse(replyFrame(), socket: socket.path)
        try await waitUntil { await publisher.started }
        await endpoint.stop()
        try await waitUntil { await publisher.cancelled }
        #expect(await endpoint.activeConnectionCount == 0)
        client.cancel()
    }

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
            let response = try await submit(frame, socket: socket.path)
            #expect(response == LocalReplyResponse(delivered: 1))
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

private func testListener() async throws -> WebSocketListener {
    let (host, _) = try await sessionHost()
    return try WebSocketListener(
        bindAddress: "127.0.0.1", port: 0, host: host,
        authorizer: PersonalTerminalAuthorizer(), hostName: "mac-main"
    )
}

private func replyFrame() -> Frame {
    let reply = ReplyDescriptor(id: UUID(), hostID: "mac-main", targetID: "tmux:reply")
    return Frame(
        timestamp: 1, target: reply.targetID, source: reply.hostID,
        payload: .text(TextPayload(text: "ready", reply: reply))
    )
}

private func sendWithoutResponse(_ frame: Frame, socket: String) throws -> NWConnection {
    var encoded = try FrameCoding.encode(frame)
    encoded.append(UInt8(ascii: "\n"))
    let request = encoded
    let connection = NWConnection(to: .unix(path: socket), using: .tcp)
    connection.stateUpdateHandler = { state in
        guard case .ready = state else { return }
        connection.send(content: request, contentContext: .defaultMessage, isComplete: false, completion: .idempotent)
    }
    connection.start(queue: DispatchQueue(label: "hail.local-reply-send-only-test"))
    return connection
}

private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LocalReplyEndpointError.failed("condition timed out")
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

private func submit(_ frame: Frame, socket: String) async throws -> LocalReplyResponse {
    let connection = NWConnection(to: .unix(path: socket), using: .tcp)
    let queue = DispatchQueue(label: "hail.local-reply-test")
    var encoded = try FrameCoding.encode(frame)
    encoded.append(UInt8(ascii: "\n"))
    let request = encoded
    return try await withCheckedThrowingContinuation { continuation in
        let completion = LocalReplyTestCompletion(continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(
                    content: request, contentContext: .defaultMessage, isComplete: false,
                    completion: .contentProcessed { error in
                        if let error { completion.fail(error) } else {
                            receiveResponse(connection, completion: completion, buffer: Data())
                        }
                    }
                )
            case .failed(let error): completion.fail(error)
            default: break
            }
        }
        connection.start(queue: queue)
    }
}

private func receiveResponse(
    _ connection: NWConnection, completion: LocalReplyTestCompletion, buffer: Data
) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, done, error in
        if let error { completion.fail(error); return }
        var response = buffer
        if let data { response.append(data) }
        if let newline = response.firstIndex(of: UInt8(ascii: "\n")) {
            do {
                completion.succeed(try JSONDecoder().decode(LocalReplyResponse.self, from: response[..<newline]))
            } catch {
                completion.fail(error)
            }
            connection.cancel()
        } else if done {
            completion.fail(LocalReplyEndpointError.failed("response ended early"))
        } else {
            receiveResponse(connection, completion: completion, buffer: response)
        }
    }
}

private final class LocalReplyTestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalReplyResponse, any Error>?

    init(_ continuation: CheckedContinuation<LocalReplyResponse, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ response: LocalReplyResponse) { finish(.success(response)) }
    func fail(_ error: any Error) { finish(.failure(error)) }

    private func finish(_ result: Result<LocalReplyResponse, any Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}

private actor BlockingReplyPublisher: HostReplyPublishing {
    private(set) var started = false
    private(set) var cancelled = false
    private var continuation: CheckedContinuation<Int, any Error>?

    func publish(_ frame: Frame) async throws -> Int {
        _ = frame
        started = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
