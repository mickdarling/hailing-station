import Foundation
import HailProtocol
extension ReplyPlaybackController {
    func handlePlaybackControl(_ control: ControlPayload, _ event: HostReplyEvent) {
        guard remember(event.frame.id) else { return }
        switch control {
        case .stopPlayback: stopPlayback(from: event.endpointID)
        case .setReplyMute(let muted): setReplyMute(muted)
        default: break
        }
    }
    /// Voice mute waits for its spoken confirmation; unmute and mute with no playback apply immediately (#404).
    func setReplyMute(_ muted: Bool) {
        guard muted else {
            pendingMuteAfter = nil
            return setMuted(false)
        }
        if let activeKey, !isMuted { pendingMuteAfter = activeKey } else { setMuted(true) }
    }
    func applyPendingMuteIfDue() {
        guard let after = pendingMuteAfter, activeKey != after, !playbackOrder.contains(after) else { return }
        pendingMuteAfter = nil
        setMuted(true)
    }
    func setMuted(_ muted: Bool) {
        if muted != isMuted { toggleMute() }
    }
    /// Stop shared playback and this host's pending replies, or every host when nil (#309, `+Headset`).
    /// Mark stopped replies complete so late frames cannot restart them.
    func stopPlayback(from endpointID: HostEndpoint.Identifier?) {
        let pending = Set(queue).union(firstAudio.keys).union(cancelledFirstAudio).union(expiredFirstAudio)
        let stopped = Set(playbackOrder).union(pending.filter { endpointID == nil || $0.endpointID == endpointID })
        cancelFirstAudio(for: stopped)
        expiredFirstAudio.subtract(stopped)
        guard !stopped.isEmpty else { return }
        player.cancel()
        playbackGeneration &+= 1
        for key in stopped {
            setPresentationStatus("Stopped", for: key)
            streams[key] = nil
            completed.insert(key)
        }
        queue.removeAll { stopped.contains($0) }
        playbackOrder.removeAll()
        activeKey = nil
        isPaused = false
        status = "Stopped"
        drain()
    }
    /// A new reply arriving while playback is paused supersedes what was paused (#321): the user paused the
    /// last answer and asked again, so the newest reply plays. The paused reply and anything queued before the
    /// new one are skipped and marked complete, so their later frames are ignored instead of starting them.
    func supersedePausedReplies() {
        guard isPaused else { return }
        let skipped = Set(playbackOrder).union(queue).union(firstAudio.keys)
            .union(cancelledFirstAudio).union(expiredFirstAudio)
        cancelFirstAudio(for: skipped)
        expiredFirstAudio.subtract(skipped)
        if !skipped.isEmpty {
            player.cancel()
            playbackGeneration &+= 1
        }
        for key in skipped {
            setPresentationStatus("Skipped", for: key)
            streams[key] = nil
            completed.insert(key)
        }
        queue.removeAll()
        playbackOrder.removeAll()
        activeKey = nil
        isPaused = false
    }
}
// First-audio arrival watches share the idle clock, scheduler and deadline (#825), independently of the player head.
extension ReplyPlaybackController {
    var hasQueuedPlayback: Bool { !queue.isEmpty }
    public var latest: ReplyPresentation? { replies.last }
    func receiveText(_ event: HostReplyEvent, descriptor: ReplyDescriptor) {
        let key = ReplyStreamKey(endpointID: event.endpointID, replyID: descriptor.id)
        let id = upsertFirstAudioText(event, descriptor: descriptor, key: key)
        guard streams[key] == nil, !completed.contains(key) else { return }
        if presentationStatuses[id] == nil { presentationStatuses[id] = "Received" }
        guard descriptor.audioStreamID != nil, presentationStatuses[id] == "Received",
              firstAudio[key] == nil, !cancelledFirstAudio.contains(key),
              !expiredFirstAudio.contains(key) else { return }
        if isMuted || pendingMuteAfter != nil { return retainCancelledFirstAudio([key]) }
        // ReplyBackground.awaitAudioTurn queues detached audio: host audio means its shared turn is in use (#825).
        let now = idleNow()
        // For a first-audio watch, bufferedUntil stays at original text arrival, anchoring the hard cap.
        let watch = ReplyIdleWatch(key: key, bufferedUntil: now, lastFrameAt: now, aheadUntil: now)
        firstAudio[key] = watch
        firstAudioByEndpoint[key.endpointID, default: []].insert(key)
        armFirstAudio(for: key)
    }
    func noteEndpointAudio(_ endpointID: HostEndpoint.Identifier) {
        for key in firstAudioByEndpoint[endpointID] ?? [] {
            firstAudio[key]?.lastFrameAt = idleNow()
            armFirstAudio(for: key)
        }
    }
    func cancelFirstAudio(for keys: Set<ReplyStreamKey>) {
        for key in keys {
            firstAudio.removeValue(forKey: key)?.cancel?()
            firstAudioByEndpoint[key.endpointID]?.remove(key)
            if firstAudioByEndpoint[key.endpointID]?.isEmpty == true { firstAudioByEndpoint[key.endpointID] = nil }
        }
        cancelledFirstAudio.subtract(keys)
    }
    func cancelMutedFirstAudio() {
        // Mute is terminal-local today; prefer no loss claim even if a host withholds audio (#825).
        guard isMuted || pendingMuteAfter != nil else { return }
        let keys = Set(firstAudio.keys)
        cancelFirstAudio(for: keys)
        retainCancelledFirstAudio(keys)
    }
    private func retainCancelledFirstAudio(_ keys: Set<ReplyStreamKey>) {
        cancelledFirstAudio.formUnion(keys)
        // Retire mute-only overflow: repeated text cannot revive its claim, nor late audio restart it (#825).
        let retired = Set(cancelledFirstAudio.prefix(max(0, cancelledFirstAudio.count - firstAudioClaimLimit)))
        completed.formUnion(retired)
        for key in retired where presentationStatuses[key.presentationID] != nil {
            presentationStatuses[key.presentationID] = "Skipped"
        }
        undeliveredLosses.subtract(retired)
        cancelledFirstAudio.subtract(retired)
    }
    func firstAudioDeadlinePassed(for key: ReplyStreamKey) {
        guard let watch = firstAudio[key], idleNow() >= firstAudioDeadline(watch) else { return }
        cancelFirstAudio(for: [key])
        guard streams[key] == nil, !completed.contains(key), !isMuted, pendingMuteAfter == nil else { return }
        // The host turn may belong to another device: claim silence once, but let late audio play (#825 / #851).
        expiredFirstAudio.append(key)
        // #825: retire a reply after 1,024 later first-audio claims; never forget its playable identity.
        if expiredFirstAudio.count > firstAudioClaimLimit, let retired = expiredFirstAudio.removeFirst() {
            completed.insert(retired)
            let id = retired.presentationID
            if presentationStatuses[id] != nil { presentationStatuses[id] = "Skipped" }
            undeliveredLosses.remove(retired)
        }
        recordAudioLoss(for: key)
        onStreamAbandoned?()
    }
}

struct ReplyStreamKey: Hashable {
    var endpointID: HostEndpoint.Identifier
    var replyID: UUID
}

struct ReplyStreamState {
    var segments: [Int: AudioPayload] = [:]
    var nextSequence = 0
}

extension ReplyStreamKey {
    static let announcementEndpoint: HostEndpoint.Identifier = "local-announcement"
    var isAnnouncement: Bool { endpointID == Self.announcementEndpoint }
}

extension ReplyPlaybackController {
    /// Retain a loss across trims until observed (#825 / #838). Without a consumer, evict the oldest first.
    func recordAudioLoss(for key: ReplyStreamKey) {
        guard !key.isAnnouncement else { return } // Local cues have no reply presentation to retain.
        undeliveredLosses.append(key)
        if undeliveredLosses.count > firstAudioClaimLimit { undeliveredLosses.removeFirst() }
        presentationStatuses[key.presentationID] = Self.abandonedStatus
    }
    /// The recorded status of every reply whose audio did not play, by presentation id, observably.
    var lostAudioStatuses: [String: String] { presentationStatuses.filter { Self.audioProblem($0.value) != nil } }
    /// Queues a local announcement behind any reply (#825 S4b). It plays through the same player, so it shares the
    /// echo canceller, pause and mute, and playback reports it as assistant speech like a reply; it is never a reply
    /// entry, and never what Replay replays.
    func enqueueAnnouncement(_ audio: [AudioPayload]) {
        let key = ReplyStreamKey(endpointID: ReplyStreamKey.announcementEndpoint, replyID: UUID())
        var stream = ReplyStreamState()
        for payload in audio { stream.segments[payload.sequence] = payload }
        streams[key] = stream
        queue.append(key)
        drain()
    }
}
extension ReplyPlaybackController {
    /// Avoid scanning pinned history or rebuilding its retention union for each new promised reply (#825).
    func upsertFirstAudioText(_ event: HostReplyEvent, descriptor: ReplyDescriptor, key: ReplyStreamKey) -> String {
        let id = key.presentationID
        guard descriptor.audioStreamID != nil, presentationStatuses[id] == nil,
              streams[key] == nil, !completed.contains(key), firstAudio[key] == nil,
              !cancelledFirstAudio.contains(key), !expiredFirstAudio.contains(key),
              case .text(let text) = event.frame.payload else {
            return upsertPresentation(event, descriptor: descriptor)
        }
        replies.append(ReplyPresentation(id: id, endpointID: event.endpointID, host: descriptor.hostID,
                                         target: descriptor.targetID, transcript: text.text))
        // These disjoint pending/loss windows are already retained, as is this new presentation.
        if replies.count > firstAudio.count + cancelledFirstAudio.count + undeliveredLosses.count + 1 {
            trimPresentations(retainingPresentationID: id)
        }
        return id
    }
}
