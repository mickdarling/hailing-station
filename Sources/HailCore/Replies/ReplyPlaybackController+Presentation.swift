import Foundation
import HailProtocol

extension ReplyPlaybackController {
    public func togglePause() {
        if isPaused {
            do {
                try player.resume()
                isPaused = false
                status = "Playing"
            } catch {
                status = "Playback could not resume"
            }
        } else {
            player.pause()
            isPaused = true
            status = "Paused"
        }
    }

    public func toggleMute() {
        isMuted.toggle()
        player.setMuted(isMuted)
        status = isMuted ? "Muted" : "Playing"
    }

    public func replayLatest() {
        guard !lastAudio.isEmpty, let lastKey else { return }
        guard activeKey == nil || activeKey == lastKey else {
            status = "Replay available when this reply finishes"
            return
        }
        playbackGeneration &+= 1
        let generation = playbackGeneration
        playbackOrder = [lastKey]
        activeKey = lastKey
        do {
            try player.replaceQueue(with: lastAudio) { [weak self] in
                self?.playbackFinished(lastKey, generation: generation)
            }
            setPresentationStatus(nil, for: lastKey)
            isPaused = false
            status = "Replaying"
        } catch {
            playbackFinished(lastKey, generation: generation)
            setPresentationStatus("Replay failed", for: lastKey)
        }
    }

    public var statusForControls: String {
        guard let presentationForControls else { return status }
        return presentationStatuses[presentationForControls.id] ?? status
    }

    func presentation(for key: ReplyStreamKey?) -> ReplyPresentation? {
        guard let key else { return nil }
        return replies.first { $0.id == presentationID(for: key) }
    }

    func setPresentationStatus(_ status: String?, for key: ReplyStreamKey) {
        guard let presentation = presentation(for: key) else { return }
        presentationStatuses[presentation.id] = status
    }

    func rollbackPlaybackStart(for key: ReplyStreamKey) {
        playbackOrder.removeAll { $0 == key }
        if activeKey == key { activeKey = playbackOrder.first }
    }

    @discardableResult
    func upsertPresentation(_ event: HostReplyEvent, descriptor: ReplyDescriptor) -> String {
        let id = "\(event.endpointID)|\(descriptor.id.uuidString.lowercased())"
        let transcript: String?
        if case .text(let text) = event.frame.payload { transcript = text.text } else { transcript = nil }
        if let index = replies.firstIndex(where: { $0.id == id }) {
            if let transcript { replies[index].transcript = transcript }
        } else {
            replies.append(ReplyPresentation(
                id: id, host: descriptor.hostID, target: descriptor.targetID, transcript: transcript
            ))
            trimPresentations(retainingPresentationID: id)
        }
        return id
    }

    func trimPresentations(retainingPresentationID: String? = nil) {
        guard replies.count > Self.presentationLimit else { return }
        var retained = Set(presentationKeysToRetain.map(presentationID(for:)))
        if let latest { retained.insert(latest.id) }
        if let retainingPresentationID { retained.insert(retainingPresentationID) }
        var excess = replies.count - Self.presentationLimit
        replies.removeAll { reply in
            guard excess > 0, !retained.contains(reply.id) else { return false }
            excess -= 1
            return true
        }
        let liveIDs = Set(replies.map(\.id))
        presentationStatuses = presentationStatuses.filter { liveIDs.contains($0.key) }
    }

    private func presentationID(for key: ReplyStreamKey) -> String {
        "\(key.endpointID)|\(key.replyID.uuidString.lowercased())"
    }

    func remember(_ id: UUID) -> Bool {
        guard seenFrameSet.insert(id).inserted else { return false }
        seenFrames.append(id)
        if seenFrames.count > Self.seenFrameLimit {
            for expired in seenFrames.prefix(seenFrames.count - Self.seenFrameLimit) {
                seenFrameSet.remove(expired)
            }
            seenFrames.removeFirst(seenFrames.count - Self.seenFrameLimit)
        }
        return true
    }

    func descriptor(in frame: Frame) -> ReplyDescriptor? {
        switch frame.payload {
        case .text(let text): text.reply
        case .audio(let audio): audio.reply
        default: nil
        }
    }
}
