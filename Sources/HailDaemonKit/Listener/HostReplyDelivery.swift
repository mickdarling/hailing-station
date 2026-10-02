import Foundation
public import HailProtocol

// Correlated and single-terminal fallback publication share one admission-and-enqueue boundary.
// swiftlint:disable file_length

enum ReplyPublicationStatus: Equatable, Sendable {
    case absent, pending, ready
}

/// Single-terminal fallback admission (#188). `ownsRequest` means this connection holds a current record
/// for the frame's request, so the correlated path already judged the frame; the fallback never overrides
/// a media, duplicate or expiry refusal of a known request.
enum UncorrelatedReplyAdmission: Equatable, Sendable {
    case unrelated, ownsRequest, selectsTarget
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

    private func replyDescriptor(_ frame: Frame) -> ReplyDescriptor? {
        switch frame.payload {
        case .text(let text): text.reply
        case .audio(let audio): audio.reply
        default: nil
        }
    }

    private func replyCandidate(_ frame: Frame) -> (UUID, HostReplyRequest)? {
        guard !Task.isCancelled, let reply = replyDescriptor(frame), let requestID = reply.requestID else { return nil }
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

    /// Side-effect-free fallback snapshot: live selection of the frame's target plus a currently issuable
    /// host permit (policy binding, tier, policy health, lockdown). No ticket is retained from it.
    func uncorrelatedReplyAdmission(_ frame: Frame) async -> UncorrelatedReplyAdmission {
        let selection = uncorrelatedReplySelection(frame)
        guard selection == .selectsTarget else { return selection }
        guard await uncorrelatedReplyPermit(frame) != nil else { return .unrelated }
        return uncorrelatedReplySelection(frame)
    }

    private func uncorrelatedReplySelection(_ frame: Frame) -> UncorrelatedReplyAdmission {
        guard !Task.isCancelled, case .ready(let version) = state, frame.version == version else { return .unrelated }
        if let requestID = replyDescriptor(frame)?.requestID, let request = replyRequests[requestID],
           request.isCurrent(at: requestClock()) { return .ownsRequest }
        guard let target = frame.target, target == selectedTarget else { return .unrelated }
        return .selectsTarget
    }

    /// Policy, exact binding, tier and lockdown are re-read from the host for every fallback attempt.
    /// There is no retained request ticket, cooperative lease or media pinning for an uncorrelated reply.
    private func uncorrelatedReplyPermit(_ frame: Frame) async -> ReplyPublicationPermit? {
        guard let target = frame.target, let listing = try? await host.registry.listing(),
              let listed = listing.first(where: { $0.info.id == target }), let binding = listed.binding,
              listed.info.alive, let sessionBinding = try? ProviderSessionBinding(
                hostID: hostName, providerID: listed.info.kind, targetID: target, sessionID: binding
              ) else { return nil }
        return await host.replyPublicationPermit(for: sessionBinding)
    }

    /// Delivers to this connection only while it still selects the target and the host permit is current.
    func enqueueUncorrelatedReply(_ frame: Frame, enqueue: @Sendable () -> Bool) async -> Bool {
        guard uncorrelatedReplySelection(frame) == .selectsTarget,
              let permit = await uncorrelatedReplyPermit(frame) else { return false }
        // Selection or state may have moved during the awaits; the gate itself rejects a revoked permit.
        guard uncorrelatedReplySelection(frame) == .selectsTarget else { return false }
        return permit.performIfCurrent { !Task.isCancelled && enqueue() } == true
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

    func uncorrelatedReplyAdmission(_ frame: Frame) async -> UncorrelatedReplyAdmission {
        let admission = await session.uncorrelatedReplyAdmission(frame)
        // A retiring transport cannot be the single recipient; a known request stays known regardless.
        if admission == .selectsTarget, prepareReplyPublication(frame) == nil { return .unrelated }
        return admission
    }

    func deliverUncorrelatedReply(_ frame: Frame) async -> Bool {
        guard !ended, let prepared = prepareReplyPublication(frame),
              await session.enqueueUncorrelatedReply(frame, enqueue: prepared.enqueue) else { return false }
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
        guard let (peer, status) = candidate else { return try await publishUncorrelated(validated) }
        // This refusal has made zero enqueue attempts. Only this code permits bounded same-frame retry.
        guard status == .ready else { throw LocalReplyRefusal.requestPending }
        // The snapshot may already be stale. Final synchronous gates decide; later send completion
        // failure is ambiguous and must never be treated as a safe pre-publication retry.
        guard await peer.deliverHostReply(validated) else { throw LocalReplyRefusal.publicationFailed }
        return 1
    }

    /// Demo-era single-terminal bridge (#188): with the opt-in flag, an uncorrelated reply (no request, or
    /// one unknown or expired everywhere) reaches the one live connection selecting its target. Zero or
    /// several selecting connections keep today's refusals; this is bounded, not a return to broadcast.
    /// Like the correlated scan, this is an admission snapshot; the chosen peer's gates decide at enqueue.
    private func publishUncorrelated(_ frame: Frame) async throws -> Int {
        guard singleTerminalReplyFallback else { throw LocalReplyRefusal.noRecipient }
        var candidates: [WebSocketPeer] = []
        var known = false
        for peer in Array(peers.values) {
            switch await peer.uncorrelatedReplyAdmission(frame) {
            case .unrelated: continue
            case .ownsRequest: known = true
            case .selectsTarget: candidates.append(peer)
            }
        }
        try Task.checkCancellation()
        guard !stopped else { throw WebSocketListenerError.stoppedBeforeReady }
        // The whole scan completes first so the refusal code never depends on peer iteration order.
        guard !known else { throw LocalReplyRefusal.noRecipient }
        guard candidates.count <= 1 else { throw LocalReplyRefusal.notUniqueRecipient }
        guard let candidate = candidates.first else { throw LocalReplyRefusal.noRecipient }
        guard await candidate.deliverUncorrelatedReply(frame) else { throw LocalReplyRefusal.publicationFailed }
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
