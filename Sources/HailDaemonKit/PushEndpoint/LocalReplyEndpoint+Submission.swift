import Foundation
public import HailProtocol
import Network

public protocol HostReplyPublishing: Sendable {
    func publish(_ frame: Frame) async throws -> Int
}

extension WebSocketListener: HostReplyPublishing {}

struct LocalReplyConnection: Sendable {
    var id: UUID
    var connection: NWConnection
}

extension LocalReplyEndpoint {
    var activeConnectionCount: Int { connections.count }
    var awaitingFrameIDs: Set<UUID> { awaitingFrames }

    func accept(_ connection: NWConnection) {
        guard !stopped, readyResult != nil, connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        awaitingFrames.insert(id)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.retire(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(LocalReplyConnection(id: id, connection: connection), buffer: Data())
        let timeout = requestTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireIncomplete(id)
        }
    }

    func frameCompleted(_ id: UUID) {
        awaitingFrames.remove(id)
    }

    func expireIncomplete(_ id: UUID) {
        guard awaitingFrames.contains(id) else { return }
        retire(id)
    }

    func expireSubmission(_ id: UUID) {
        guard submissionTasks[id] != nil else { return }
        retire(id)
    }

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
            frameCompleted(client.id)
            guard newline == request.index(before: request.endIndex) else {
                await respond(.init(delivered: 0, error: "one frame per connection"), to: client)
                return
            }
            startSubmission(Data(request[..<newline]), from: client)
        } else if done {
            await respond(.init(delivered: 0, error: "unterminated frame"), to: client)
        } else {
            receive(client, buffer: request)
        }
    }

    func startSubmission(_ data: Data, from client: LocalReplyConnection) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.submit(data, from: client)
        }
        submissionTasks[client.id] = task
        let timeout = submissionTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireSubmission(client.id)
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
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let frame = try FrameCoding.decode(data)
            guard let target = frame.target else { throw LocalReplyEndpointError.failed("reply target missing") }
            _ = try await audit.record(.pushed(tool: "local-reply", target: target, bytes: data.count))
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let delivered = try await destination.publish(frame)
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            await respond(.init(delivered: delivered), to: client)
        } catch is CancellationError {
            retire(client.id)
        } catch {
            if !stopped, connections[client.id] != nil {
                await respond(.init(delivered: 0, error: "reply refused"), to: client)
            } else {
                retire(client.id)
            }
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
        awaitingFrames.remove(id)
        submissionTasks.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
