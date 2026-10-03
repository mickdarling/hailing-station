public import Foundation
import OSLog
import HailProtocol

// Request shape, session gate, peer lifecycle binding and socket submission form one dispatch boundary.
// swiftlint:disable file_length

private let dispatchLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "local-dispatch")

/// A prompt dispatched over the owner-only local reply socket on behalf of one connection (#188 item 1,
/// part B). The host runs that peer's own ingress path, so the named phone becomes the reply owner exactly
/// as if it had spoken the text. `connection` is the listener's peer UUID (`sessionID` on
/// `session_connected`), never a Hello device name.
public struct LocalDispatchRequest: Codable, Sendable, Equatable {
    public static let kind = "dispatch"
    /// The dispatched prompt's byte cap: the local RightyO prompt cap (#200), not the phone text payload's.
    public static let maxTextBytes = HailHost.localPromptSanitizing.maxUTF8Bytes
    /// The socket line cap for one dispatch: JSON escaping (`\"`, `\/`) can double the text, plus the envelope.
    public static let maxLineBytes = 2 * maxTextBytes + 4 * 1024
    public var connection: UUID
    public var target: String
    /// The listing binding the caller saw. A changed binding refuses rather than following the rebind.
    public var binding: String
    public var text: String

    public init(connection: UUID, target: String, binding: String, text: String) {
        self.connection = connection
        self.target = target
        self.binding = binding
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case kind, connection, target, binding, text }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == Self.kind else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "not a dispatch")
        }
        connection = try container.decode(UUID.self, forKey: .connection)
        target = try container.decode(String.self, forKey: .target)
        binding = try container.decode(String.self, forKey: .binding)
        text = try container.decode(String.self, forKey: .text)
        guard !target.isEmpty, !binding.isEmpty, text.utf8.count <= Self.maxTextBytes else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: container, debugDescription: "out of range")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(connection, forKey: .connection)
        try container.encode(target, forKey: .target)
        try container.encode(binding, forKey: .binding)
        try container.encode(text, forKey: .text)
    }
}

/// Stable dispatch refusals. The wire `code` reuses the reply vocabulary; `error` names the exact reason.
public enum LocalDispatchRefusal: String, Error, Sendable, Equatable {
    case unsupported, unknownConnection, connectionEnded, sessionNotReady, notAuthorized, targetNotSelected
    case selectionChanged, bindingMismatch, confirmationRequired, capacityExceeded, deliveryRefused
    case ownershipLost, connectionLost

    public var message: String {
        let reason = switch self {
        case .unsupported: "destination cannot dispatch"
        case .unknownConnection: "no live connection has that id"
        case .connectionEnded: "connection has ended"
        case .sessionNotReady: "connection has not negotiated"
        case .notAuthorized: "connection is not authorized to send text"
        case .targetNotSelected: "connection does not select that target"
        case .selectionChanged: "connection reselected while the dispatch was pending"
        case .bindingMismatch: "target binding differs from the pinned binding"
        case .confirmationRequired: "target requires confirmation at the Mac"
        case .capacityExceeded: "connection holds too many live requests"
        case .deliveryRefused: "target action was refused"
        case .ownershipLost: "handed off, but no reply ownership survived"
        case .connectionLost: "handed off, but the connection ended before it could own the reply"
        }
        return "dispatch refused [\(rawValue)]: \(reason)"
    }

    public var code: LocalReplyRefusal {
        switch self {
        case .unknownConnection, .connectionEnded, .sessionNotReady, .notAuthorized, .targetNotSelected,
             .selectionChanged, .connectionLost: .noRecipient
        default: .publicationFailed
        }
    }

    /// Only these follow a completed handoff; every other refusal committed nothing.
    public var handedOff: Bool { self == .ownershipLost || self == .connectionLost }
}

extension WebSocketListener {
    /// Resolves the operator-visible connection id and runs that peer's own ingress path. A stale or
    /// unknown id refuses; there is no fallback to whichever connection currently selects the target.
    public func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        guard !stopped, readyResult != nil else { throw WebSocketListenerError.stoppedBeforeReady }
        guard let peer = peers[request.connection] else { throw LocalDispatchRefusal.unknownConnection }
        let owner = try await peer.dispatch(request)
        // Membership is rechecked after the handoff: a peer that left the listing cannot be an owner.
        guard peers[request.connection] === peer else {
            await peer.session.revokeDispatch(owner)
            throw LocalDispatchRefusal.connectionLost
        }
        return owner
    }
}

extension WebSocketPeer {
    /// Binds the dispatch to this peer's own lifecycle (ended, closing, retired transport) at both ends of
    /// the session handoff; the caller's task cancellation is a separate outcome and never revokes a live
    /// peer's record. The handoff itself cannot hold the transport gate (the session cannot read it
    /// synchronously), so a peer that ends during the handoff has its minted record revoked and the caller
    /// is told the connection was lost.
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        guard isLive else { throw LocalDispatchRefusal.connectionEnded }
        let owner = try await session.dispatch(request)
        guard isLive else {
            await session.revokeDispatch(owner)
            throw LocalDispatchRefusal.connectionLost
        }
        return owner
    }
}

extension HostSession {
    static let dispatchDevice = "rightyo-local"

    /// The phone's text-frame path with the caller's pinned binding: the session's own authorizer on the
    /// exact frame that will be delivered, then lease, permit, capacity, lifetime and generation, then
    /// `HailHost.send`, then commit after delivery. Returns the committed request id, or nil when the
    /// adapter accepts only legacy generic input and so cannot own a reply. The host sanitises the prompt
    /// under its local-prompt cap (#200), bound here and nowhere else; every other gate is the phone's.
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        try await HailHost.$localDispatchIngress.withValue(true) { try await dispatchScoped(request) }
    }

    private func dispatchScoped(_ request: LocalDispatchRequest) async throws -> UUID? {
        try Task.checkCancellation()
        // The selection generation seen here is the one the dispatch is bound to: a reselection of the same
        // target while this call is suspended (A → B → A) revokes it like any other selection change.
        let (version, generation) = try requireSelection(of: request)
        // One final text frame, judged once by the authorizer every phone frame passes; its id is the
        // utterance id the host receives, and the session attributes it to the fixed local device, not to
        // anything the caller wrote. A connection-probe session yields nothing, whatever it selects.
        guard var input = await authorize(Frame(
            version: version, timestamp: now(), target: request.target, source: Self.dispatchDevice,
            payload: .text(TextPayload(text: request.text))
        ), device: Self.dispatchDevice) else { throw LocalDispatchRefusal.notAuthorized }
        input.expectedBinding = request.binding
        try requireSelection(of: request, generation: generation)
        let listing = try await host.registry.listing()
        guard let listed = listing.first(where: { $0.info.id == request.target }), listed.info.alive,
              listed.binding == request.binding else { throw LocalDispatchRefusal.bindingMismatch }
        // No suspension between this check and `deliver`'s own generation snapshot: the two cannot diverge.
        try requireSelection(of: request, generation: generation)
        switch await deliver(input) {
        case .delivered(let owner): return owner
        case .selectionChanged: throw LocalDispatchRefusal.selectionChanged
        case .confirmationRequired: throw LocalDispatchRefusal.confirmationRequired
        case .unowned: throw LocalDispatchRefusal.ownershipLost
        case .refused(.rateLimited, _): throw LocalDispatchRefusal.capacityExceeded
        // The host refuses a cancelled caller before its handoff; that is the caller's outcome, not a refusal
        // of the target, and nothing was sent.
        case .refused where Task.isCancelled: throw CancellationError()
        case .refused: throw LocalDispatchRefusal.deliveryRefused
        }
    }

    /// Drops a request whose named connection is gone; a reply to it would otherwise be refused anyway.
    func revokeDispatch(_ owner: UUID?) {
        if let owner { replyRequests[owner] = nil }
    }

    /// Negotiated, selecting the target and, once bound, still on the captured selection generation.
    @discardableResult
    private func requireSelection(
        of request: LocalDispatchRequest, generation: UUID? = nil
    ) throws -> (version: Int, generation: UUID) {
        guard case .ready(let version) = state else { throw LocalDispatchRefusal.sessionNotReady }
        guard selectedTarget == request.target else { throw LocalDispatchRefusal.targetNotSelected }
        if let generation, generation != selectionGeneration { throw LocalDispatchRefusal.selectionChanged }
        return (version, selectionGeneration)
    }
}

extension LocalReplyEndpoint {
    /// Same admission budget and audit boundary as a reply. The socket now carries input, trusting its
    /// 0600/uid boundary for the caller; the prompt still takes the full sanitizer and policy path.
    func submitDispatch(_ data: Data, from client: LocalReplyConnection) async {
        do {
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let request = try Self.decodeDispatch(data)
            do {
                _ = try await audit.record(.pushed(tool: "local-dispatch", target: request.target, bytes: data.count))
            } catch {
                dispatchLogger.error("Local dispatch audit failed: \(String(reflecting: error), privacy: .private)")
                throw LocalReplyRefusal.auditFailure
            }
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let owner = try await destination.dispatch(request)
            guard !Task.isCancelled, !stopped, connections[client.id] != nil else {
                // The handoff completed; the named connection keeps its ownership. Only the answer is lost.
                dispatchLogger.notice("Local dispatch handed off, but its caller went away before the answer")
                throw CancellationError()
            }
            await respond(.dispatch(delivered: 1, request: owner), to: client)
        } catch is CancellationError {
            // Before the handoff nothing was sent; after it, the record stands. Neither is a refusal.
            retire(client.id)
        } catch {
            let refusal = error as? LocalDispatchRefusal
            let reason = LocalReplyRefusal(error)
            let named = refusal?.rawValue ?? reason.rawValue
            dispatchLogger.error("Local dispatch refused (\(named)): \(String(reflecting: error), privacy: .private)")
            guard !stopped, connections[client.id] != nil else { return retire(client.id) }
            await respond(.dispatch(
                delivered: refusal?.handedOff == true ? 1 : 0, request: nil,
                error: refusal?.message ?? reason.message, code: refusal?.code ?? reason
            ), to: client)
        }
    }

    private static func decodeDispatch(_ data: Data) throws -> LocalDispatchRequest {
        do { return try JSONDecoder().decode(LocalDispatchRequest.self, from: data) } catch {
            dispatchLogger.error("Local dispatch decode failed: \(String(reflecting: error), privacy: .private)")
            throw LocalReplyRefusal.decodeFailure
        }
    }
}
