import Foundation
import HailProtocol

extension ReplyPlaybackController {
    /// Makes microphone capture strictly half-duplex with reply playback. New reply frames may
    /// continue to queue, but none are scheduled or resumed until capture finalization releases the
    /// suppression. A user's explicit pause choice remains authoritative across the transition.
    public func beginCaptureSuppression() {
        guard !isCaptureSuppressed else { return }
        isCaptureSuppressed = true
        if !isPaused, activeKey != nil {
            player.pause()
        }
        status = "Paused while listening"
    }

    public func endCaptureSuppression(resumingPlayback: Bool = true) {
        guard isCaptureSuppressed else { return }
        isCaptureSuppressed = false
        guard resumingPlayback else {
            if activeKey != nil || hasQueuedPlayback {
                isPaused = true
                status = "Paused"
            } else {
                status = isMuted ? "Muted" : "Ready for replies"
            }
            return
        }
        guard !isPaused else {
            status = "Paused"
            return
        }
        if activeKey != nil {
            do {
                try player.resume()
                status = isMuted ? "Muted" : "Playing"
                drain()
            } catch {
                status = "Playback could not resume"
            }
        } else {
            if !hasQueuedPlayback {
                status = isMuted ? "Muted" : "Ready for replies"
            } else {
                drain()
            }
        }
    }

    public func togglePause() {
        if isCaptureSuppressed {
            isPaused.toggle()
            status = isPaused ? "Paused" : "Paused while listening"
            return
        }
        if isPaused {
            do {
                try player.resume()
                isPaused = false
                status = isMuted ? "Muted" : "Playing"
                drain()
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
        status = isCaptureSuppressed ? "Paused while listening" : (isMuted ? "Muted" : "Playing")
    }

    public func replayLatest() {
        guard !isCaptureSuppressed else {
            status = "Replay available after listening"
            return
        }
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
        if isCaptureSuppressed { return "Paused while listening" }
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
                id: id, endpointID: event.endpointID, host: descriptor.hostID,
                target: descriptor.targetID, transcript: transcript
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
