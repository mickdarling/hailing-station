import Foundation
public import HailProtocol

/// A host-minted request belongs to this HostSession only. Neither device names nor wire UUIDs create it.
struct HostReplyRequest {
    static let capacity = 64
    static let lifetimeMilliseconds: Int64 = 120_000
    static let frameLimit = 1_024
    let context: ProviderTurnContext
    let generation: UUID
    let createdAt: Int64
    var committed = false
    var descriptor: ReplyDescriptor?
    var textDelivered = false
    var audioSequence = 0
    var audioFinished = false
    var frames: Set<UUID> = []

    func isCurrent(at timestamp: Int64) -> Bool {
        let elapsed = timestamp.subtractingReportingOverflow(createdAt)
        return !elapsed.overflow && elapsed.partialValue >= 0 && elapsed.partialValue < Self.lifetimeMilliseconds
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
        let timestamp = now()
        replyRequests = replyRequests.filter { $0.value.isCurrent(at: timestamp) }
    }

    /// Pending/failed, legacy, stale and other-connection requests never acquire recipient authority.
    func acceptsHostReply(_ frame: Frame) async -> Bool {
        let reply: ReplyDescriptor?
        switch frame.payload {
        case .text(let text): reply = text.reply
        case .audio(let audio): reply = audio.reply
        default: return false
        }
        pruneReplyRequests()
        guard let reply, let requestID = reply.requestID, let original = replyRequests[requestID],
              original.committed, frame.target == original.context.binding.targetID else { return false }
        guard let listing = try? await host.registry.listing(),
              let listed = listing.first(where: { $0.info.id == original.context.binding.targetID }),
              listed.info.alive, listed.binding == original.context.binding.sessionID,
              listed.info.kind == original.context.binding.providerID else {
            replyRequests[requestID] = nil
            return false
        }
        guard await host.permitsReply(original.context.binding) else {
            replyRequests[requestID] = nil
            return false
        }
        // Recheck after every actor hop: selection or closure may have invalidated the original request.
        guard case .ready(let version) = state, frame.version == version,
              var request = replyRequests[requestID], request.committed, request.isCurrent(at: now()),
              request.generation == selectionGeneration, selectedTarget == frame.target,
              request.context == original.context, request.accept(frame, descriptor: reply) else { return false }
        replyRequests[requestID] = request
        return true
    }
}

extension HailHost {
    /// Read the host's in-memory authority in one actor turn, not across separate reentrant snapshots.
    func permitsReply(_ binding: ProviderSessionBinding) -> Bool {
        guard policyFailure == nil, !lockdown.isOn,
              let allowed = currentPolicy.targets[binding.targetID],
              allowed.binding == binding.sessionID, allowed.tier != .locked else { return false }
        return true
    }
}

extension WebSocketPeer {
    /// Returns true only for this negotiated connection's successfully dispatched, still-current request.
    func deliverHostReply(_ frame: Frame) async -> Bool {
        guard !ended, await session.acceptsHostReply(frame) else { return false }
        guard await send(frame) else {
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
