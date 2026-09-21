public import HailProtocol

extension WebSocketPeer {
    /// Returns true only when this negotiated peer selected the reply's target and accepted the frame.
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
    /// Publishes one already-completed host reply to every negotiated terminal selecting its target.
    /// Encoding and decoding at this trust boundary applies the same size, identity, stream, and provenance
    /// validation as a network sender; programmatically constructed mismatches cannot bypass it.
    @discardableResult
    public func publish(_ frame: Frame) async throws -> Int {
        guard !stopped, readyResult != nil else { throw WebSocketListenerError.stoppedBeforeReady }
        guard let encoded = try? FrameCoding.encode(frame),
              let validated = try? FrameCoding.decode(encoded),
              validated == frame,
              validated.source == hostName else { throw WebSocketListenerError.invalidReply }
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
