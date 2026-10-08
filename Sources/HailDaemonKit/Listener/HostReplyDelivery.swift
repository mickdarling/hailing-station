import Foundation
public import HailProtocol

// Correlated and single-terminal fallback publication share one admission-and-enqueue boundary.
// swiftlint:disable file_length

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

    private func replyDescriptor(_ frame: Frame) -> ReplyDescriptor? {
        switch frame.payload {
        case .text(let text): text.reply
        case .audio(let audio): audio.reply
        default: nil
        }
    }

    private func replyCandidate(_ frame: Frame) -> (UUID, HostReplyRequest)? {
        guard !Task.isCancelled, let reply = replyDescriptor(frame), let requestID = reply.requestID,
              !stoppedReplies.contains(reply.id) else { return nil }
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
            noteReplyDelivered(frame)
            return true
        }) == true else {
            replyRequests[requestID] = nil
            return false
        }
        return true
    }

    /// Side-effect-free single-terminal fallback snapshot (#188): a request-less reply, live selection of
    /// its target and a currently issuable host permit (policy binding, tier, policy health, lockdown).
    /// No ticket is retained from it.
    func admitsRequestlessReply(_ frame: Frame) async -> Bool {
        guard selectsRequestlessReplyTarget(frame), await requestlessReplyPermit(frame) != nil else { return false }
        return selectsRequestlessReplyTarget(frame)
    }

    /// Any explicit request reference, owned or not, stays on the correlated path. Only the plain
    /// `haild reply --say` shape may fall back, so a stale reference can never reach another connection.
    private func selectsRequestlessReplyTarget(_ frame: Frame) -> Bool {
        guard !Task.isCancelled, case .ready(let version) = state, frame.version == version,
              let reply = replyDescriptor(frame), reply.requestID == nil, !stoppedReplies.contains(reply.id),
              let target = frame.target, target == selectedTarget else { return false }
        return true
    }

    /// Policy, exact binding, tier and lockdown are re-read from the host for every fallback attempt.
    /// There is no retained request ticket, cooperative lease or media pinning for a request-less reply.
    private func requestlessReplyPermit(_ frame: Frame) async -> ReplyPublicationPermit? {
        guard let target = frame.target, let listing = try? await host.registry.listing(),
              let listed = listing.first(where: { $0.info.id == target }), let binding = listed.binding,
              listed.info.alive, let sessionBinding = try? ProviderSessionBinding(
                hostID: hostName, providerID: listed.info.kind, targetID: target, sessionID: binding
              ) else { return nil }
        return await host.replyPublicationPermit(for: sessionBinding)
    }

    /// Delivers to this connection only while it still selects the target and the host permit is current.
    func enqueueRequestlessReply(_ frame: Frame, enqueue: @Sendable () -> Bool) async -> Bool {
        guard selectsRequestlessReplyTarget(frame),
              let permit = await requestlessReplyPermit(frame) else { return false }
        // Selection or state may have moved during the awaits; the gate itself rejects a revoked permit.
        guard selectsRequestlessReplyTarget(frame) else { return false }
        guard permit.performIfCurrent({ !Task.isCancelled && enqueue() }) == true else { return false }
        noteReplyDelivered(frame)
        return true
    }

    /// Tracks which replies' audio is mid-stream on this connection, so a stop knows what to cut (#309).
    private func noteReplyDelivered(_ frame: Frame) {
        guard case .audio(let audio) = frame.payload, let reply = audio.reply else { return }
        repliesInFlight.removeAll { $0 == reply.id }
        guard !audio.isFinal else { return }
        // An abandoned stream never sends its final frame, so the oldest entry gives way: a live reply is always
        // tracked, and a stale one can at worst be stopped again.
        repliesInFlight.append(reply.id)
        repliesInFlight.removeFirst(max(0, repliesInFlight.count - Self.playbackStopLimit))
    }

    static let playbackStopLimit = 64

    func hasStopped(_ frame: Frame) -> Bool {
        Self.replyID(frame).map(stoppedReplies.contains) ?? false
    }

    nonisolated static func replyID(_ frame: Frame) -> UUID? {
        switch frame.payload {
        case .text(let text): text.reply?.id
        case .audio(let audio): audio.reply?.id
        default: nil
        }
    }

    /// A `dismiss` asked to stop playback (#309). Every reply mid-stream on this connection is stopped: its
    /// remaining frames are refused, so the reply CLI retires its renderer. The `stop_playback` frame is
    /// returned only for a ready device that advertised it; an older device would refuse it as malformed.
    func stopReplyPlayback() -> (frame: Frame?, stopped: [UUID]) {
        guard case .ready(let version) = state else { return (nil, []) }
        let stopped = repliesInFlight
        stoppedReplies.append(contentsOf: repliesInFlight)
        stoppedReplies.removeFirst(max(0, stoppedReplies.count - Self.playbackStopLimit))
        repliesInFlight.removeAll()
        guard peerCapabilities.contains(PlaybackStop.capability) else { return (nil, stopped) }
        return (response(.stopPlayback, version: version), stopped)
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

    func admitsRequestlessReply(_ frame: Frame) async -> Bool {
        guard await session.admitsRequestlessReply(frame) else { return false }
        // A retiring transport cannot be the single recipient.
        return prepareReplyPublication(frame) != nil
    }

    func deliverRequestlessReply(_ frame: Frame) async -> Bool {
        guard !ended, let prepared = prepareReplyPublication(frame),
              await session.enqueueRequestlessReply(frame, enqueue: prepared.enqueue) else { return false }
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
        // A reply stopped on any connection is refused everywhere (#309), so a stop can never hand the rest of it
        // to another connection that also selects its target. The listener's record outlives the connection; the
        // per-session scan covers a stop still between its session and the listener.
        if let id = HostSession.replyID(validated), stoppedReplyIDs.contains(id) {
            throw LocalReplyRefusal.replyStopped
        }
        for peer in Array(peers.values) where await peer.session.hasStopped(validated) {
            throw LocalReplyRefusal.replyStopped
        }
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
        guard let (peer, status) = candidate else {
            let delivered = try await publishUncorrelated(validated)
            ambient?.observeReply(validated)
            return delivered
        }
        // This refusal has made zero enqueue attempts. Only this code permits bounded same-frame retry.
        guard status == .ready else { throw LocalReplyRefusal.requestPending }
        // The snapshot may already be stale. Final synchronous gates decide; later send completion
        // failure is ambiguous and must never be treated as a safe pre-publication retry.
        guard await peer.deliverHostReply(validated) else { throw LocalReplyRefusal.publicationFailed }
        ambient?.observeReply(validated) // Own-voice rejection for ambient requests (#269).
        return 1
    }

    /// Demo-era single-terminal bridge (#188): with the opt-in flag, a reply carrying no request reference
    /// reaches the one live connection selecting its target. Any explicit reference that is not currently
    /// owned keeps today's refusal, as do zero or several selecting connections; this is bounded, not a
    /// return to broadcast. The scan is a snapshot; uniqueness is not rescanned at enqueue.
    private func publishUncorrelated(_ frame: Frame) async throws -> Int {
        guard singleTerminalReplyFallback else { throw LocalReplyRefusal.noRecipient }
        var candidates: [WebSocketPeer] = []
        for peer in Array(peers.values) where await peer.admitsRequestlessReply(frame) {
            candidates.append(peer)
        }
        try Task.checkCancellation()
        guard !stopped else { throw WebSocketListenerError.stoppedBeforeReady }
        // The whole scan completes first so the refusal code never depends on peer iteration order.
        guard candidates.count <= 1 else { throw LocalReplyRefusal.notUniqueRecipient }
        guard let candidate = candidates.first else { throw LocalReplyRefusal.noRecipient }
        guard await candidate.deliverRequestlessReply(frame) else { throw LocalReplyRefusal.publicationFailed }
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
