import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// Endpoint cancellation runs through the real peer outcome handler with a held synthetic send completion.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LocalReplyEndpointSendDeadline904Tests {
    // This full endpoint-to-peer proof keeps setup, assertions and teardown in one scope.
    // swiftlint:disable:next function_body_length
    @Test func submissionDeadlineRefusesAmbiguouslyWithoutDisconnectingSession() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "h904-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (host, _) = try await sessionHost()
        let events = Mutex<[WebSocketListenerEvent]>([])
        let peer = WebSocketPeer(
            id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: HostSession(host: host), queue: DispatchQueue(label: "synthetic-deadline-peer"),
            helloTimeout: .seconds(5), log: { event in events.withLock { $0.append(event) } }, onEnd: { _ in }
        )
        let transport = ReplyTransportLifecycle()
        let callback = Mutex<(@Sendable (NWError?) -> Void)?>(nil)
        let submitted = AsyncStream<Void>.makeStream()
        let ticket = PreparedWebSocketReply(permit: try #require(transport.issuePermit()), submit: { completion in
            callback.withLock { $0 = completion }
            submitted.continuation.yield(())
        }, cancel: { reason in Task { await peer.finish(reason: reason) } })
        let publisher = SlowReplyPublisher904(ticket: ticket, peer: peer)
        let socket = scratch.appendingPathComponent("config/\(LocalReplyEndpoint.socketName)")
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: publisher,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")),
            submissionTimeout: .milliseconds(100)
        )
        try await endpoint.start()
        let client = NWConnection(to: .unix(path: socket.path), using: .tcp)
        client.start(queue: DispatchQueue(label: "synthetic-deadline-client"))
        let reply = ReplyDescriptor(id: UUID(), hostID: "synthetic-host", targetID: "tmux:synthetic")
        let frame = Frame(timestamp: 1, target: reply.targetID, source: reply.hostID,
                          payload: .text(TextPayload(text: "synthetic reply", reply: reply)))
        var data = try FrameCoding.encode(frame)
        data.append(UInt8(ascii: "\n"))
        client.send(content: data, completion: .idempotent)
        var submissions = submitted.stream.makeAsyncIterator()
        _ = try #require(await submissions.next())
        var outcomes = publisher.outcomes.stream.makeAsyncIterator()
        #expect(await outcomes.next() == .abandoned)
        let response = await withCheckedContinuation { continuation in
            client.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, done, error in
                continuation.resume(returning: (data ?? Data(), done, error))
            }
        }
        #expect(response.0.isEmpty && response.1 && response.2 == nil) // Lost acknowledgement, never success/retry.
        #expect(await endpoint.activeConnectionCount == 0)
        #expect(await peer.isLive)
        #expect(!(await peer.ended))
        #expect(!transport.isRetired)
        #expect(events.withLock { $0.map(\.event) } == ["host_reply_send_abandoned"])
        let complete = try #require(callback.withLock { stored in
            defer { stored = nil }
            return stored
        })
        complete(nil)
        let next = PreparedWebSocketReply(permit: try #require(transport.issuePermit()), submit: { $0(nil) })
        #expect(next.enqueue())
        #expect(await next.result() == .sent)
        client.cancel()
        await endpoint.stop()
        await peer.finish(reason: "synthetic cleanup")
        submitted.continuation.finish()
        publisher.outcomes.continuation.finish()
    }

    @Test(arguments: [false, true])
    func lateFailureOrStallLogsSpecificDisconnect(stalls: Bool) async throws {
        let (host, _) = try await sessionHost()
        let disconnected = AsyncStream<String>.makeStream()
        let peer = WebSocketPeer(
            id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: HostSession(host: host), queue: DispatchQueue(label: "synthetic-failure-peer"),
            helloTimeout: .seconds(5), log: { event in
                if event.event == "session_disconnected" { disconnected.continuation.yield(event.detail ?? "") }
            }, onEnd: { _ in }
        )
        let transport = ReplyTransportLifecycle()
        let callback = Mutex<(@Sendable (NWError?) -> Void)?>(nil)
        let ticket = PreparedWebSocketReply(permit: try #require(transport.issuePermit()), submit: { completion in
            callback.withLock { $0 = completion }
        }, cancel: { reason in Task { await peer.finish(reason: reason) } },
        stallGrace: stalls ? .milliseconds(20) : .seconds(5))
        #expect(ticket.enqueue())
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ticket.result()
        }
        #expect(await waiter.value == .abandoned)
        if !stalls { callback.withLock { $0 }?(.posix(.EPIPE)) }
        var closures = disconnected.stream.makeAsyncIterator()
        let expected = stalls ? "host reply send stalled" : "host reply send failed: \(NWError.posix(.EPIPE))"
        #expect(await closures.next() == expected)
        #expect(await peer.ended)
        #expect(transport.isRetired)
        // Release the held completion even after the watchdog won.
        let complete = callback.withLock { stored in
            defer { stored = nil }
            return stored
        }
        complete?(nil)
        disconnected.continuation.finish()
    }
}

private final class SlowReplyPublisher904: HostReplyPublishing {
    let outcomes = AsyncStream<PreparedWebSocketReply.Outcome>.makeStream()
    private let ticket: PreparedWebSocketReply
    private let peer: WebSocketPeer

    init(ticket: PreparedWebSocketReply, peer: WebSocketPeer) {
        self.ticket = ticket
        self.peer = peer
    }

    func publish(_ frame: Frame) async throws -> Int {
        guard ticket.enqueue() else { throw LocalReplyRefusal.publicationFailed }
        let outcome = await ticket.result()
        let sent = await peer.replySendSucceeded(outcome)
        outcomes.continuation.yield(outcome)
        guard sent else { throw LocalReplyRefusal.publicationFailed }
        return 1
    }
}
