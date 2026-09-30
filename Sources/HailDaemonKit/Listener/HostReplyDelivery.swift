import Foundation
public import HailProtocol

enum ReplyPublicationStatus: Equatable, Sendable {
    case absent, pending, ready
}

/// A host-minted request belongs to this HostSession only. Neither device names nor wire UUIDs create it.
struct HostReplyRequest {
    static let capacity = 64
    static let lifetime: Duration = .seconds(120)
    static let frameLimit = 1_024
    let context: ProviderTurnContext
    let generation: UUID
    let createdAt: ContinuousClock.Instant
    let policyPermit: ReplyPublicationPermit
    let bindingLease: ProviderReplyBindingLease
    var committed = false
    var descriptor: ReplyDescriptor?
    var textDelivered = false
    var audioSequence = 0
    var audioFinished = false
    var frames: Set<UUID> = []

    func isCurrent(at timestamp: ContinuousClock.Instant) -> Bool {
        let elapsed = createdAt.duration(to: timestamp)
        return elapsed >= .zero && elapsed < Self.lifetime
    }

    /// Keep these exact admission tickets: revocation followed by restoration cannot revive a request.
    func withAuthority<Result>(_ operation: () -> Result) -> Result? {
        guard let result = policyPermit.performIfCurrent({ bindingLease.performIfCurrent(operation) }) else {
            return nil
        }
        return result
    }

    mutating func accept(_ frame: Frame, descriptor reply: ReplyDescriptor) -> Bool {
        guard frames.count < Self.frameLimit, !frames.contains(frame.id),
              descriptor == nil || descriptor == reply else { return false }
        switch frame.payload {
        case .text(let text):
            guard text.isFinal, !textDelivered else { return false }
            textDelivered = true
        case .audio(let audio):
            guard !audioFinished, audio.streamID == reply.audioStreamID, audio.streamID != nil,
                  audio.sequence == audioSequence else { return false }
            audioSequence += 1
            audioFinished = audio.isFinal
        default: return false
        }
        descriptor = reply
        frames.insert(frame.id)
        return true
    }
}

extension HostSession {
    func pruneReplyRequests() {
        let timestamp = requestClock()
        replyRequests = replyRequests.filter {
            $0.value.isCurrent(at: timestamp) && $0.value.withAuthority { true } == true
        }
    }

    /// A side-effect-free admission snapshot, not publication authority. Media is checked on a copy;
    /// actual enqueue must repeat the recipient/media checks under the retained authority gates.
    func replyPublicationStatus(_ frame: Frame) -> ReplyPublicationStatus {
        guard let (_, request) = replyCandidate(frame) else { return .absent }
        return request.withAuthority {
            guard !Task.isCancelled, request.isCurrent(at: requestClock()) else { return .absent }
            return request.committed ? .ready : .pending
        } ?? .absent
    }

    private func replyCandidate(_ frame: Frame) -> (UUID, HostReplyRequest)? {
        let reply: ReplyDescriptor?
        switch frame.payload {
        case .text(let text): reply = text.reply
        case .audio(let audio): reply = audio.reply
        default: return nil
        }
        guard !Task.isCancelled, let reply, let requestID = reply.requestID else { return nil }
        guard case .ready(let version) = state, frame.version == version,
              var request = replyRequests[requestID], request.isCurrent(at: requestClock()),
              request.generation == selectionGeneration, selectedTarget == frame.target,
              request.context.connectionID == connectionID,
              frame.target == request.context.binding.targetID,
              request.accept(frame, descriptor: reply) else { return nil }
        return (requestID, request)
    }

    /// Pending/failed, legacy, stale and other-connection requests never acquire recipient authority.
    /// The enqueue must be synchronous and non-reentrant; no Boolean authorization leaves this actor.
    func enqueueHostReply(_ frame: Frame, enqueue: @Sendable () -> Bool) -> Bool {
        pruneReplyRequests()
        guard let (requestID, request) = replyCandidate(frame), request.committed else { return false }
        // Policy, cooperative binding, recipient/media state and actual network submission share one
        // no-await commit. Recheck expiry after waiting for the gates; completion is awaited outside them.
        guard request.withAuthority({
            guard !Task.isCancelled, request.isCurrent(at: requestClock()), enqueue() else { return false }
            replyRequests[requestID] = request
            return true
        }) == true else {
            replyRequests[requestID] = nil
            return false
        }
        return true
    }
}

extension WebSocketPeer {
    func replyPublicationStatus(_ frame: Frame) async -> ReplyPublicationStatus {
        // Terminal retirement precedes actor callbacks. Preparation is side-effect-free, and final
        // enqueue independently rechecks transport authority rather than trusting this status snapshot.
        guard prepareReplyPublication(frame) != nil else { return .absent }
        let status = await session.replyPublicationStatus(frame)
        guard prepareReplyPublication(frame) != nil else { return .absent }
        return status
    }

    /// Returns true only for this negotiated connection's successfully dispatched, still-current request.
    func deliverHostReply(_ frame: Frame) async -> Bool {
        guard !ended, let prepared = prepareReplyPublication(frame),
              await session.enqueueHostReply(frame, enqueue: prepared.enqueue) else { return false }
        guard await prepared.result() else {
            finish(reason: "host reply send failed")
            return false
        }
        return true
    }
}

extension WebSocketListener {
    /// Publishes a correlated reply only to its requesting connection; ambiguous legacy replies reach nobody.
    /// Encoding and decoding at this trust boundary applies the same size, identity, stream, and provenance
    /// validation as a network sender; programmatically constructed mismatches cannot bypass it.
    @discardableResult
    public func publish(_ frame: Frame) async throws -> Int {
        guard !stopped, readyResult != nil else { throw WebSocketListenerError.stoppedBeforeReady }
        let validated = try validatedReply(frame)
        // Fresh host-minted UUIDs establish origin ownership. This scan is an admission snapshot,
        // not a transactional global directory or a UUID-collision proof. Never enqueue during it.
        var candidate: (WebSocketPeer, ReplyPublicationStatus)?
        for peer in Array(peers.values) {
            let status = await peer.replyPublicationStatus(validated)
            guard status != .absent else { continue }
            guard candidate == nil else { throw LocalReplyRefusal.notUniqueRecipient }
            candidate = (peer, status)
        }
        try Task.checkCancellation()
        guard !stopped else { throw WebSocketListenerError.stoppedBeforeReady }
        guard let (peer, status) = candidate else { throw LocalReplyRefusal.noRecipient }
        // This refusal has made zero enqueue attempts. Only this code permits bounded same-frame retry.
        guard status == .ready else { throw LocalReplyRefusal.requestPending }
        // The snapshot may already be stale. Final synchronous gates decide; later send completion
        // failure is ambiguous and must never be treated as a safe pre-publication retry.
        guard await peer.deliverHostReply(validated) else { throw LocalReplyRefusal.publicationFailed }
        return 1
    }

    private func validatedReply(_ frame: Frame) throws -> Frame {
        guard let encoded = try? FrameCoding.encode(frame),
              let validated = try? FrameCoding.decode(encoded),
              validated == frame else {
            throw WebSocketListenerError.invalidReply
        }
        guard validated.source.compare(
            hostName, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedSame else { throw WebSocketListenerError.sourceHostMismatch }
        switch validated.payload {
        case .text(let text) where text.isFinal && text.reply != nil: break
        case .audio(let audio) where audio.reply != nil: break
        default: throw WebSocketListenerError.invalidReply
        }
        return validated
    }
}
