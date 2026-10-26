import Foundation
import HailProtocol
import Synchronization

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
            let delivery = await peer.deliverRequestlessReply(frame, onLateSuccess: lateEchoObservation(frame))
            guard case .delivered = delivery else { return "refused" }
            ambient?.observeReply(frame)
        }
        return "sent"
    }
}

extension HostSession {
    /// The user's own ambient request as heard (#318), only while this ready session still selects `target`, only to a
    /// device that advertised `AmbientHeard.capability`, and only text the command can carry: anything else is nil.
    func heardFrame(_ text: String, target: String) -> Frame? {
        guard case .ready(let version) = state, selectedTarget == target,
              peerCapabilities.contains(AmbientHeard.capability),
              (1...PayloadLimits.maxTextBytes).contains(text.utf8.count) else { return nil }
        return response(.ambientHeard(targetID: target, text: text), version: version)
    }
}

extension HostSession {
    /// A turn heard but not sent (#398), only while this ready session still selects `target`, only to a device that
    /// advertised `AmbientOverheard.capability`, only within the scope it asked for (`owner` sends the owner's turns,
    /// `everyone` all; `off` nothing), and only text the command can carry: anything else is nil. A guest's `name`
    /// (#434) rides only on someone else's turn, only to a device that advertised `AmbientOverheard.namesCapability`,
    /// and only if the protocol accepts it; otherwise the turn goes unnamed.
    func overheardFrame(_ text: String, owner: Bool, name: String? = nil, target: String) -> Frame? {
        guard case .ready(let version) = state, selectedTarget == target,
              peerCapabilities.contains(AmbientOverheard.capability),
              overheardScope == "everyone" || (overheardScope == "owner" && owner),
              (1...PayloadLimits.maxTextBytes).contains(text.utf8.count),
              (1...PayloadLimits.maxTextBytes).contains(target.utf8.count) else { return nil }
        let speaker = owner ? "owner" : "other"
        let named = owner || !peerCapabilities.contains(AmbientOverheard.namesCapability)
            ? nil : AmbientOverheard.name(name)
        return response(.ambientOverheard(targetID: target, text: text, speaker: speaker, name: named),
                        version: version)
    }
}

extension WebSocketListener {
    /// Shows the connection that heard a turn it did not send (#398), queued like `ambient_heard`. Only that connection
    /// is told, within its own scope; the text is never logged. Returns whether the frame was queued.
    @discardableResult
    func showAmbientOverheard(
        connection: UUID, target: String, text: String, owner: Bool, name: String? = nil
    ) async -> Bool {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }),
              let frame = await peer.session.overheardFrame(text, owner: owner, name: name, target: target) else {
            return false
        }
        return await peer.post(frame)
    }
}

extension WebSocketListener {
    /// Shows the connection that heard an admitted request what it heard (#318), before the request is typed. Only
    /// that connection is told. A device that cannot show it, or no longer selects `target`, gets nothing, and the
    /// request is delivered as before. The text is never logged. Returns whether the frame was queued: it waits for
    /// the connection to take it, not for it to go out, so a stalled phone cannot hold up the typing.
    @discardableResult
    func showAmbientHeard(connection: UUID, target: String, text: String, request: UUID = UUID()) async -> Bool {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return false
        }
        let records = heardTurns[connection] ?? HeardTurnRecords()
        heardTurns[connection] = records
        return await peer.postAmbientHeard(text, target: target, request: request, records: records)
    }

    func finishHeardRequest(_ request: UUID, connection: UUID) {
        _ = heardTurns[connection]?.take(request)
    }
}

extension WebSocketPeer {
    /// Mint at the enqueue boundary, without suspension between minting, successful post and recording. A failed
    /// queue records nothing. The session's existing ambient-heard gate still applies, independently of heard_turns.
    func postAmbientHeard(_ text: String, target: String, request: UUID, records: HeardTurnRecords) async -> Bool {
        guard var frame = await session.heardFrame(text, target: target) else { return false }
        let capable = await session.peerCapabilities.contains(HeardTurns.capability)
        guard isLive else { return false }
        let turn = capable ? UUID() : nil
        frame.payload = .control(.ambientHeard(targetID: target, text: text, turn: turn))
        guard post(frame) else { return false }
        if let turn { records.record(request, turn: turn) }
        return true
    }
}

/// One connection's in-memory FIFO, with no content or producer identifiers. Closing prevents a late enqueue from
/// reviving records after teardown; a refusal takes its key once, and completion discards it. The listener retains
/// one ledger per live connection, bounded by its connection limit; this ledger holds at most 64 entries.
final class HeardTurnRecords: Sendable {
    static let capacity = 64
    private struct State {
        var entries: [(request: UUID, turn: UUID)] = []
        var closed = false
    }
    private let state = Mutex(State())
    var count: Int { state.withLock { $0.entries.count } }

    func record(_ request: UUID, turn: UUID) {
        state.withLock { state in
            guard !state.closed else { return }
            state.entries.removeAll { $0.request == request }
            if state.entries.count == Self.capacity { state.entries.removeFirst() }
            state.entries.append((request, turn))
        }
    }

    func take(_ request: UUID) -> UUID? {
        state.withLock { state in
            guard let index = state.entries.firstIndex(where: { $0.request == request }) else { return nil }
            return state.entries.remove(at: index).turn
        }
    }

    func close() { state.withLock { $0.closed = true; $0.entries.removeAll() } }
}
