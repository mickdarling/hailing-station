import Foundation
import HailProtocol
import Network

struct LocalReplyConnection: Sendable {
    var id: UUID
    var connection: NWConnection
}

extension LocalReplyEndpoint {
    func receive(_ client: LocalReplyConnection, buffer: Data) {
        client.connection.receive(
            minimumIncompleteLength: 1, maximumLength: 8 * 1024
        ) { [weak self] data, _, done, error in
            Task { await self?.received(data, done: done, error: error, client: client, buffer: buffer) }
        }
    }

    func received(
        _ data: Data?, done: Bool, error: (any Error)?, client: LocalReplyConnection, buffer: Data
    ) async {
        guard connections[client.id] != nil, error == nil else {
            retire(client.id)
            return
        }
        var request = buffer
        if let data { request.append(data) }
        guard request.count <= PayloadLimits.defaultMaxFrameBytes + 1 else {
            await respond(.init(delivered: 0, error: "frame too large"), to: client)
            return
        }
        if let newline = request.firstIndex(of: UInt8(ascii: "\n")) {
            guard newline == request.index(before: request.endIndex) else {
                await respond(.init(delivered: 0, error: "one frame per connection"), to: client)
                return
            }
            await submit(Data(request[..<newline]), from: client)
        } else if done {
            await respond(.init(delivered: 0, error: "unterminated frame"), to: client)
        } else {
            receive(client, buffer: request)
        }
    }

    func submit(_ data: Data, from client: LocalReplyConnection) async {
        let now = clock.now
        guard limiter.retryAfter(
            for: "local-reply", now: now, limitPerMinute: Self.maxFramesPerMinute
        ) == nil else {
            await respond(.init(delivered: 0, error: "rate limited"), to: client)
            return
        }
        limiter.record("local-reply", at: now)
        do {
            let frame = try FrameCoding.decode(data)
            guard let target = frame.target else { throw LocalReplyEndpointError.failed("reply target missing") }
            _ = try await audit.record(.pushed(tool: "local-reply", target: target, bytes: data.count))
            await respond(.init(delivered: try await destination.publish(frame)), to: client)
        } catch {
            await respond(.init(delivered: 0, error: "reply refused"), to: client)
        }
    }

    func respond(_ response: LocalReplyResponse, to client: LocalReplyConnection) async {
        var data = (try? JSONEncoder().encode(response)) ?? Data(#"{"delivered":0,"error":"internal"}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        await withCheckedContinuation { continuation in
            client.connection.send(
                content: data, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
        retire(client.id)
    }

    func retire(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }
}
