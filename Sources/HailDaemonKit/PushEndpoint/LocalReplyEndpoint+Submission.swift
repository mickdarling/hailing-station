public import Foundation
import OSLog
public import HailProtocol
import Network

// Reply and dispatch requests share one socket admission, response and retirement path.
// swiftlint:disable file_length

private let replyLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "local-reply")

public protocol HostReplyPublishing: Sendable {
    /// requestPending may be thrown only for a unique valid uncommitted request, before any enqueue.
    /// Later failures must not use that retryable code, even when delivery completion is unknown.
    func publish(_ frame: Frame) async throws -> Int
    /// Runs the named connection's own ingress path for `request.text` (#188); the result is the committed
    /// request id, or nil when the target's adapter cannot own a reply. Refusals throw.
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID?
    /// `haild ambient reload|status` (#405): restarts or describes the active ambient stream's child.
    func ambient(_ request: LocalAmbientRequest) async -> LocalAmbientReport
}

extension HostReplyPublishing {
    /// A destination that cannot dispatch fails closed rather than publishing input anywhere.
    public func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        throw LocalDispatchRefusal.unsupported
    }

    /// A destination without ambient wiring touches nothing.
    public func ambient(_ request: LocalAmbientRequest) async -> LocalAmbientReport {
        LocalAmbientReport(outcome: .notEnabled)
    }
}

extension WebSocketListener: HostReplyPublishing {}

struct LocalReplyConnection: Sendable {
    var id: UUID
    var connection: NWConnection
}

public struct LocalReplyResponse: Codable, Equatable, Sendable {
    public var delivered: Int
    public var error: String?
    /// Only explicit requestPending with zero deliveries permits bounded same-frame retry.
    /// Older hosts omit this field; absence never implies retry permission.
    public var code: LocalReplyRefusal?
    /// Dispatch responses (#188) always carry this key: the host-minted request the pane must echo back
    /// through `haild reply --request`, or explicit `null` when no reply ownership exists. Reply
    /// responses omit the key, byte for byte as before.
    public var request: UUID?
    public private(set) var isDispatch = false
    /// Ambient answers (#405) only; every other response omits the key, byte for byte as before.
    public var ambient: LocalAmbientReport?

    public init(delivered: Int, error: String? = nil, code: LocalReplyRefusal? = nil) {
        self.delivered = delivered
        self.error = error
        self.code = code
    }

    public static func dispatch(
        delivered: Int, request: UUID?, error: String? = nil, code: LocalReplyRefusal? = nil
    ) -> Self {
        var response = Self(delivered: delivered, error: error, code: code)
        (response.request, response.isDispatch) = (request, true)
        return response
    }

    public static func ambient(_ report: LocalAmbientReport) -> Self {
        var response = Self(delivered: 0)
        response.ambient = report
        return response
    }

    private enum CodingKeys: String, CodingKey { case delivered, error, code, request, ambient }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delivered = try container.decode(Int.self, forKey: .delivered)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        code = try container.decodeIfPresent(LocalReplyRefusal.self, forKey: .code)
        isDispatch = container.contains(.request)
        request = try container.decodeIfPresent(UUID.self, forKey: .request)
        ambient = try container.decodeIfPresent(LocalAmbientReport.self, forKey: .ambient)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(delivered, forKey: .delivered)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(code, forKey: .code)
        if isDispatch { try container.encode(request, forKey: .request) }
        try container.encodeIfPresent(ambient, forKey: .ambient)
    }
}

/// The optional top-level discriminator of a local request; a frame has none and keeps today's path.
private struct LocalRequestKind: Decodable {
    var kind: String?
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
            minimumIncompleteLength: 1, maximumLength: 64 * 1024
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
        // The line cap is the dispatch cap (#200); `submit` holds reply frames to their own, unchanged.
        guard request.count <= Self.maxLineBytes + 1 else {
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

    static let maxLineBytes = max(PayloadLimits.defaultMaxFrameBytes, LocalDispatchRequest.maxLineBytes)

    func submit(_ data: Data, from client: LocalReplyConnection) async {
        // Only the exact `dispatch` and `ambient` kinds leave the reply path; a frame or any other shape is a reply.
        let kind = (try? JSONDecoder().decode(LocalRequestKind.self, from: data))?.kind
        let isDispatch = kind == LocalDispatchRequest.kind
        // A reply frame keeps the pre-#200 line cap and answer; only a dispatch may use the larger line.
        guard isDispatch || data.count <= PayloadLimits.defaultMaxFrameBytes else {
            return await respond(.init(delivered: 0, error: "frame too large"), to: client)
        }
        let now = clock.now
        guard limiter.retryAfter(
            for: "local-reply", now: now, limitPerMinute: Self.maxFramesPerMinute
        ) == nil else {
            await respond(.init(delivered: 0, error: "rate limited"), to: client)
            return
        }
        limiter.record("local-reply", at: now)
        if isDispatch { return await submitDispatch(data, from: client) }
        if kind == LocalAmbientRequest.kind { return await submitAmbient(data, from: client) }
        await submitReply(data, from: client)
    }

    private func submitReply(_ data: Data, from client: LocalReplyConnection) async {
        var refusedTarget: String?
        do {
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let frame = try Self.decodeLocalReply(data)
            guard let target = frame.target else { throw LocalReplyRefusal.replyTargetMissing }
            refusedTarget = target
            do {
                _ = try await audit.record(.pushed(tool: "local-reply", target: target, bytes: data.count))
            } catch {
                replyLogger.error("Local reply audit failed: \(String(reflecting: error), privacy: .private)")
                throw LocalReplyRefusal.auditFailure
            }
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let delivered = try await destination.publish(frame)
            guard delivered == 1 else {
                throw delivered == 0 ? LocalReplyRefusal.noRecipient : LocalReplyRefusal.publicationFailed
            }
            guard !Task.isCancelled, !stopped, connections[client.id] != nil else { throw CancellationError() }
            await respond(.init(delivered: delivered), to: client)
        } catch is CancellationError {
            retire(client.id)
        } catch {
            let reason = LocalReplyRefusal(error)
            replyLogger.error(
                "Local reply refused (\(reason.rawValue)): \(String(reflecting: error), privacy: .private)"
            )
            // `haild doctor` counts refusals by reason (#247); the record holds the code, never reply text.
            // `requestPending` is a retryable not-yet-ready answer that a streamed reply may get on many frames;
            // `replyStopped` is the user's own stop (#309), not a delivery fault.
            if reason != .auditFailure, reason != .requestPending, reason != .replyStopped {
                _ = try? await audit.record(.deliveryRefused(
                    target: refusedTarget ?? "unknown", device: "local-reply", reason: reason.rawValue
                ))
            }
            if !stopped, connections[client.id] != nil {
                await respond(.init(delivered: 0, error: reason.message, code: reason), to: client)
            } else {
                retire(client.id)
            }
        }
    }

    private static func decodeLocalReply(_ data: Data) throws -> Frame {
        do { return try FrameCoding.decode(data) } catch {
            replyLogger.error("Local reply decode failed: \(String(reflecting: error), privacy: .private)")
            throw LocalReplyRefusal.decodeFailure
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
