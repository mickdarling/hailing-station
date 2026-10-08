import Foundation
import HailProtocol

extension HostSession {
    /// The acknowledgement for the ambient stream's own `target` (rightyo#105), only while this ready session still
    /// selects it: an optional final text frame with the clip's words, which marks the request as heard in the
    /// thread, then the clip as one final audio frame, under one request-less reply.
    func acknowledgementFrames(_ clip: AmbientAckClip, target: String) -> [Frame]? {
        guard case .ready(let version) = state, selectedTarget == target else { return nil }
        let stream = UUID()
        let reply = ReplyDescriptor(id: UUID(), hostID: hostName, targetID: target, audioStreamID: stream)
        var frames: [Frame] = []
        if let text = clip.text {
            frames.append(Frame(version: version, timestamp: now(), target: target, source: hostName,
                                payload: .text(TextPayload(text: text, isFinal: true, reply: reply))))
        }
        frames.append(Frame(version: version, timestamp: now(), target: target, source: hostName, payload: .audio(
            AudioPayload(codec: .pcm16, sampleRate: clip.sampleRate, channels: 1, sequence: 0, streamID: stream,
                         isFinal: true, bytes: clip.pcm, reply: reply)
        )))
        return frames
    }
}

extension WebSocketListener {
    /// Plays `clip` on the connection that heard the request (rightyo#105), through the guarded request-less
    /// delivery: the connection's selection, the host permit (policy, binding, tier, lockdown) and the transport
    /// permit all apply, and nothing goes to any other connection. It is host-originated to one named connection,
    /// so it does not need the single-terminal fallback flag. Returns a fixed outcome token: `sent`,
    /// `no_connection`, `not_ready` (no negotiated session, or the phone no longer selects `target`) or `refused`.
    func acknowledgeAmbient(connection: UUID, target: String, clip: AmbientAckClip) async -> String {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return "no_connection"
        }
        guard let frames = await peer.session.acknowledgementFrames(clip, target: target) else { return "not_ready" }
        for frame in frames {
            guard await peer.deliverRequestlessReply(frame) else { return "refused" }
            ambient?.observeReply(frame)
        }
        return "sent"
    }
}
