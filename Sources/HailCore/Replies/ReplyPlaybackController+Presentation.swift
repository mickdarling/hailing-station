import Foundation
import HailProtocol
extension ReplyPlaybackController {
    /// Capture holds reply playback; new frames queue and a user pause remains authoritative.
    public func beginCaptureSuppression() {
        defer { syncIdleHold() }
        guard !isCaptureSuppressed else { return }
        isCaptureSuppressed = true
        if !isPaused, activeKey != nil {
            player.pause()
        }
        status = "Paused while listening"
    }
    public func endCaptureSuppression(resumingPlayback: Bool = true) {
        defer { syncIdleHold() }
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
        if !prepareProactiveAudibility() { drain(); return }
        if activeKey != nil {
            do {
                try player.resume()
                status = playingStatus
                drain()
            } catch {
                isPaused = true
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
        defer { syncIdleHold() }
        if isCaptureSuppressed {
            isPaused.toggle()
            status = isPaused ? "Paused" : "Paused while listening"
            return
        }
        if isPaused {
            if !prepareProactiveAudibility() { isPaused = false; drain(); return }
            do {
                try player.resume()
                isPaused = false
                status = playingStatus
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
        let canUnmute = !isMuted || prepareProactiveAudibility()
        isMuted.toggle()
        player.setMuted(isMuted)
        status = isCaptureSuppressed ? "Paused while listening" : playingStatus
        if !canUnmute { drain() }
    }
    public func replayLatest() {
        guard !isCaptureSuppressed else {
            status = "Replay available after listening"
            return
        }
        guard !lastAudio.isEmpty, let lastKey, allowProactiveReplay() else { return }
        guard activeKey == nil || activeKey == lastKey else {
            status = "Replay available when this reply finishes"
            return
        }
        if lastAudio.contains(where: \.isSegmentEnd) {
            replaySegmented(lastKey)
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
            noteReplay(lastAudio)
            setPresentationStatus(nil, for: lastKey)
            isPaused = false
            syncIdleHold() // a replay tapped while paused unpauses: the idle watch is no longer held (#469)
            status = "Replaying"
        } catch {
            playbackFinished(lastKey, generation: generation)
            setPresentationStatus("Replay failed", for: lastKey)
        }
    }
}
extension ReplyPlaybackController {
    public var statusForControls: String {
        if isCaptureSuppressed { return "Paused while listening" }
        guard let presentationForControls else { return status }
        return presentationStatuses[presentationForControls.id] ?? status
    }
    public func status(for reply: ReplyPresentation) -> String {
        if let recorded = presentationStatuses[reply.id] { return recorded }
        if presentationForControls?.id == reply.id { return statusForControls }
        return "Received"
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
            if descriptor.sessionUpdateID != nil { replies[index].isSessionUpdate = true }
        } else {
            var presentation = ReplyPresentation(
                id: id, endpointID: event.endpointID, host: descriptor.hostID,
                target: descriptor.targetID, transcript: transcript
            )
            presentation.isSessionUpdate = descriptor.sessionUpdateID != nil
            replies.append(presentation)
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
}
extension ReplyPlaybackController {
    private func replaySegmented(_ key: ReplyStreamKey) {
        playbackGeneration &+= 1
        player.cancel()
        playbackOrder = []
        activeKey = nil
        queue = [key] + queue.filter { $0 != key }
        streams[key] = ReplyStreamState(segments: Dictionary(uniqueKeysWithValues: lastAudio.map { ($0.sequence, $0) }))
        idleWatch.aheadUntil = idleNow()
        idleWatch.bufferedUntil = idleNow()
        idleWatch.heldRemaining = nil
        isPaused = false
        setPresentationStatus(nil, for: key)
        drain()
        syncIdleHold()
        if activeKey == key { status = "Replaying" }
    }
}
