import Foundation
public import HailProtocol

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

    /// Pending/failed, legacy, stale and other-connection requests never acquire recipient authority.
    /// The enqueue must be synchronous and non-reentrant; no Boolean authorization leaves this actor.
    func enqueueHostReply(_ frame: Frame, enqueue: @Sendable () -> Bool) -> Bool {
        let reply: ReplyDescriptor?
        switch frame.payload {
        case .text(let text): reply = text.reply
        case .audio(let audio): reply = audio.reply
        default: return false
        }
        pruneReplyRequests()
        guard let reply, let requestID = reply.requestID else { return false }
        guard case .ready(let version) = state, frame.version == version,
              var request = replyRequests[requestID], request.committed, request.isCurrent(at: requestClock()),
              request.generation == selectionGeneration, selectedTarget == frame.target,
              request.context.connectionID == connectionID,
              frame.target == request.context.binding.targetID,
              request.accept(frame, descriptor: reply) else { return false }
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
        var delivered = 0
        for peer in peers.values where await peer.deliverHostReply(validated) { delivered += 1 }
        return delivered
    }
}
