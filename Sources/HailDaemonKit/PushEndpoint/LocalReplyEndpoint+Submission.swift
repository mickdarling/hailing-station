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
    func replyAudio(_ request: LocalReplyAudioRequest) async throws -> LocalReplyAudioReport
    /// Runs the named connection's own ingress path for `request.text` (#188); the result is the committed
    /// request id, or nil when the target's adapter cannot own a reply. Refusals throw.
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID?
    /// `haild ambient reload|status` (#405): restarts or describes the active ambient stream's child.
    func ambient(_ request: LocalAmbientRequest) async -> LocalAmbientReport
    /// `haild notify` (#609): applies the session update policy; the update's text is never logged.
    func sessionUpdate(_ request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport
    func voiceGuardsStatus() async -> LocalVoiceGuardsReport?
    func taskProgress(_ request: LocalTaskProgressRequest) async -> LocalTaskProgressReport
}

/// Effective daemon policy, not a file snapshot. Unknown values fail decoding rather than defaulting to on.
public struct LocalVoiceGuardsReport: Codable, Equatable, Sendable {
    public enum Value: String, Codable, Sendable, CaseIterable { case on, off, unusable }
    public let value: Value
    public let enforced: Bool

    public init(value: Value, enforced: Bool) {
        self.value = value
        self.enforced = enforced
    }
}

/// Owner-only queue ordering; tickets have no authority to bypass ordinary reply admission.
public struct LocalReplyAudioTicket: Codable, Equatable, Sendable {
    public let epoch: UUID
    public let position: UInt64
    public let releaseKey: UUID?
    public init(epoch: UUID, position: UInt64, releaseKey: UUID? = nil) {
        self.epoch = epoch; self.position = position; self.releaseKey = releaseKey
    }
}

public struct LocalReplyAudioRequest: Codable, Sendable {
    public let kind: String
    public let action: String
    public let ticket: LocalReplyAudioTicket?
    public let frame: Frame?
    public init(action: String, ticket: LocalReplyAudioTicket? = nil, frame: Frame? = nil) {
        kind = "reply-audio"
        self.action = action; self.ticket = ticket; self.frame = frame
    }
}

public struct LocalReplyAudioReport: Codable, Equatable, Sendable {
    public var ticket: LocalReplyAudioTicket?
    public var skipped: Bool
    public var reason: String?
    public init(ticket: LocalReplyAudioTicket? = nil, skipped: Bool = false, reason: String? = nil) {
        self.ticket = ticket; self.skipped = skipped; self.reason = reason
    }
}

extension HostReplyPublishing {
    public func replyAudio(_ request: LocalReplyAudioRequest) async throws -> LocalReplyAudioReport {
        throw LocalReplyRefusal.invalidReplyPayload
    }

    public func voiceGuardsStatus() async -> LocalVoiceGuardsReport? { nil }

    /// A destination that cannot dispatch fails closed rather than publishing input anywhere.
    public func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        throw LocalDispatchRefusal.unsupported
    }

    /// A destination without ambient wiring touches nothing.
    public func ambient(_ request: LocalAmbientRequest) async -> LocalAmbientReport {
        LocalAmbientReport(outcome: .notEnabled)
    }

    /// A destination without session updates holds and speaks nothing.
    public func sessionUpdate(_ request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport {
        LocalSessionUpdateReport(outcome: .notEnabled)
    }

    public func taskProgress(_ request: LocalTaskProgressRequest) async -> LocalTaskProgressReport {
        .init(outcome: "not_enabled", reason: "requires_task_progress_and_session_updates")
    }
}

extension WebSocketListener: HostReplyPublishing {
    public func voiceGuardsStatus() async -> LocalVoiceGuardsReport? { await host.voiceGuardsStatus }
}

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
    /// Session update answers (#609) only; every other response omits the key.
    public var update: LocalSessionUpdateReport?
    public var progress: LocalTaskProgressReport?
    public var voiceGuards: LocalVoiceGuardsReport?
    public var replyAudio: LocalReplyAudioReport?
    /// Presence matters for version negotiation: an explicit null is not an older daemon response.
    public private(set) var isReplyAudio = false

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

    public static func update(_ report: LocalSessionUpdateReport) -> Self {
        var response = Self(delivered: 0)
        response.update = report
        return response
    }

    public static func progress(_ report: LocalTaskProgressReport) -> Self {
        var response = Self(delivered: 0)
        response.progress = report
        return response
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.delivered == rhs.delivered && lhs.error == rhs.error && lhs.code == rhs.code
            && lhs.request == rhs.request && lhs.isDispatch == rhs.isDispatch && lhs.ambient == rhs.ambient
            && lhs.update == rhs.update && lhs.progress == rhs.progress && lhs.voiceGuards == rhs.voiceGuards
            && lhs.replyAudio == rhs.replyAudio
    }

    private enum CodingKeys: String, CodingKey {
        case delivered, error, code, request, ambient, update, progress, voiceGuards, replyAudio
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delivered = try container.decode(Int.self, forKey: .delivered)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        code = try container.decodeIfPresent(LocalReplyRefusal.self, forKey: .code)
        isDispatch = container.contains(.request)
        request = try container.decodeIfPresent(UUID.self, forKey: .request)
        ambient = try container.decodeIfPresent(LocalAmbientReport.self, forKey: .ambient)
        update = try container.decodeIfPresent(LocalSessionUpdateReport.self, forKey: .update)
        progress = try container.decodeIfPresent(LocalTaskProgressReport.self, forKey: .progress)
        voiceGuards = try container.decodeIfPresent(LocalVoiceGuardsReport.self, forKey: .voiceGuards)
        isReplyAudio = container.contains(.replyAudio)
        replyAudio = try container.decodeIfPresent(LocalReplyAudioReport.self, forKey: .replyAudio)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(delivered, forKey: .delivered)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(code, forKey: .code)
        if isDispatch { try container.encode(request, forKey: .request) }
        try container.encodeIfPresent(ambient, forKey: .ambient)
        try container.encodeIfPresent(update, forKey: .update)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(voiceGuards, forKey: .voiceGuards)
        try container.encodeIfPresent(replyAudio, forKey: .replyAudio)
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
        replyLogger.error("Local submission deadline expired while submission still running; delivery is ambiguous")
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
    /// A reply's terminal audio frame ends a stream the phone otherwise keeps at the head of its playback queue
    /// (#467). It is admitted from this budget of its own, never the shared one, so other local traffic filling the
    /// shared window cannot leave a stream unterminated. One per stream; well above any real rate, still bounded.
    static let maxTerminalFramesPerMinute = 30

    /// Only the frame's type and `final` flag are read here; the full frame is decoded and checked as before.
    fileprivate struct TerminalProbe: Decodable {
        let type: String?
        let payload: TerminalProbePayload?
        static func isTerminalAudio(_ data: Data) -> Bool {
            guard let probe = try? JSONDecoder().decode(Self.self, from: data) else { return false }
            return probe.type == "audio" && probe.payload?.final == true
        }
    }

    func submit(_ data: Data, from client: LocalReplyConnection) async {
        // Only recognized local control kinds leave the reply path; anything else is a reply.
        let kind = (try? JSONDecoder().decode(LocalRequestKind.self, from: data))?.kind
        let isDispatch = kind == LocalDispatchRequest.kind
        // A reply frame keeps the pre-#200 line cap and answer; only a dispatch may use the larger line.
        guard isDispatch || data.count <= PayloadLimits.defaultMaxFrameBytes else {
            return await respond(.init(delivered: 0, error: "frame too large"), to: client)
        }
        // Content-free capability cleanup must still work after the shared publication bucket fills.
        if kind == "reply-audio", (try? Self.decodeReplyAudio(data))?.action == "release" {
            return await submitReplyAudio(data, from: client)
        }
        let now = clock.now
        let terminal = kind == nil && TerminalProbe.isTerminalAudio(data)
            || kind == "reply-audio" && QueuedTerminalProbe.isTerminalAudio(data)
        let (bucket, limit) = terminal ? ("local-reply-terminal", Self.maxTerminalFramesPerMinute)
            : ("local-reply", Self.maxFramesPerMinute)
        guard limiter.retryAfter(for: bucket, now: now, limitPerMinute: limit) == nil else {
            await respond(.init(delivered: 0, error: "rate limited"), to: client)
            return
        }
        limiter.record(bucket, at: now)
        if kind == "voice-guards" { return await submitVoiceGuards(data, from: client) }
        if isDispatch { return await submitDispatch(data, from: client) }
        if kind == LocalAmbientRequest.kind { return await submitAmbient(data, from: client) }
        if kind == LocalSessionUpdateRequest.kind { return await submitSessionUpdate(data, from: client) }
        if kind == LocalTaskProgressRequest.kind { return await submitTaskProgress(data, from: client) }
        if kind == "reply-audio" { return await submitReplyAudio(data, from: client) }
        await submitReply(data, from: client)
    }

    private static func decodeReplyAudio(_ data: Data) throws -> LocalReplyAudioRequest {
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LocalReplyRefusal.decodeFailure
        }
        let action = fields["action"] as? String
        let keys: Set<String> = action == "release" ? ["kind", "action", "ticket"] : action == "enqueue"
            ? ["kind", "action"] : ["kind", "action", "ticket", "frame"]
        guard Set(fields.keys) == keys || fields["action"] as? String == "enqueue"
                && Set(fields.keys) == keys.union(["frame"]) else { throw LocalReplyRefusal.decodeFailure }
        if let ticket = fields["ticket"] as? [String: Any],
           !Set(ticket.keys).isSubset(of: ["epoch", "position", "releaseKey"]) {
            throw LocalReplyRefusal.decodeFailure
        }
        // Check the envelope before Frame's provenance decoder can reject an absent target generically.
        if fields["action"] as? String == "publish", let frame = fields["frame"] as? [String: Any],
           frame["target"] == nil || frame["target"] is NSNull { throw LocalReplyRefusal.replyTargetMissing }
        do { return try JSONDecoder().decode(LocalReplyAudioRequest.self, from: data) } catch {
            throw LocalReplyRefusal.decodeFailure
        }
    }

    private func submitReplyAudio(_ data: Data, from client: LocalReplyConnection) async {
        var refusedTarget: String?
        do {
            let request = try Self.decodeReplyAudio(data)
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            // Publication keeps the same audit-before-delivery boundary as an ordinary reply frame.
            if request.action == "publish", let frame = request.frame {
                guard let target = frame.target else { throw LocalReplyRefusal.replyTargetMissing }
                refusedTarget = target
                do {
                    _ = try await audit.record(.pushed(tool: "local-reply", target: target,
                                                      bytes: data.count))
                } catch { throw LocalReplyRefusal.auditFailure }
            }
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let report = try await destination.replyAudio(request)
            if report.reason == "capacity" {
                _ = try? await audit.record(.deliveryRefused(target: request.frame?.target ?? "unknown",
                    device: "local-reply", reason: "replyAudioCapacity"))
            }
            guard !Task.isCancelled, !stopped, connections[client.id] != nil else { throw CancellationError() }
            var response = LocalReplyResponse(delivered: request.action == "publish" && !report.skipped ? 1 : 0)
            response.replyAudio = report
            await respond(response, to: client)
        } catch is CancellationError {
            retire(client.id)
        } catch {
            let reason = LocalReplyRefusal(error)
            replyLogger.error(
                "Local reply refused (\(reason.rawValue)): \(String(reflecting: error), privacy: .private)"
            )
            if reason != .auditFailure, reason != .requestPending, reason != .replyStopped {
                _ = try? await audit.record(.deliveryRefused(
                    target: refusedTarget ?? "unknown", device: "local-reply", reason: reason.rawValue
                ))
            }
            // Queue support is explicit on refusals too, so malformed requests never select legacy audio.
            var response = LocalReplyResponse(delivered: 0, error: reason.message, code: reason)
            response.replyAudio = LocalReplyAudioReport()
            await respond(response, to: client)
        }
    }

    /// Uses the same secured socket, frame bounds and admission budget as the other local status queries.
    /// Unlike mutating requests, this read performs no audit or policy I/O and holds no admission lock.
    private func submitVoiceGuards(_ data: Data, from client: LocalReplyConnection) async {
        guard !Task.isCancelled, !stopped, connections[client.id] != nil else { return retire(client.id) }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              request == ["kind": "voice-guards", "action": "status"] else {
            return await respond(.init(delivered: 0, error: LocalReplyRefusal.decodeFailure.message,
                                       code: .decodeFailure), to: client)
        }
        let report = await destination.voiceGuardsStatus()
        guard !Task.isCancelled, !stopped, connections[client.id] != nil else { return retire(client.id) }
        var response = LocalReplyResponse(delivered: 0)
        response.voiceGuards = report
        await respond(response, to: client)
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

/// The `final` flag of a reply frame's payload, absent meaning false (#467 terminal budget).
private struct TerminalProbePayload: Decodable {
    let final: Bool
    private enum CodingKeys: String, CodingKey { case final }
    init(from decoder: any Decoder) throws {
        final = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .final) ?? false
    }
}

/// Wrapped audio keeps the terminal frame's independent budget, including for a queued job.
private struct QueuedTerminalProbe: Decodable {
    let action: String
    let frame: LocalReplyEndpoint.TerminalProbe?
    static func isTerminalAudio(_ data: Data) -> Bool {
        guard let probe = try? JSONDecoder().decode(Self.self, from: data) else { return false }
        return probe.action == "publish" && probe.frame?.type == "audio" && probe.frame?.payload?.final == true
    }
}
