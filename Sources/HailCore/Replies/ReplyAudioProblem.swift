import HailProtocol

/// A reply whose audio did not play says so on its entry (#825, #822). Only real losses count: a stream that ended
/// without its final audio (#469), or audio that failed to play. A refused duplicate segment is not one (the first copy
/// plays), nor a replay or a resume that failed after the reply was heard.
extension ReplyPlaybackController {
    public nonisolated static let playbackFailed = "Playback failed"
    public nonisolated static let audioFormatNotPlayable = "Audio format is not yet playable"
    public nonisolated static let audioCouldNotBeDecoded = "Audio couldn't be decoded"
    public nonisolated static let audioDidNotArrive = "Audio didn't arrive in full"
    public nonisolated static let audioCouldNotPlay = "Audio couldn't play"
    /// The status of a stream that ended without its final audio (#469), for the app's deferred announcements.
    public nonisolated static var endedWithoutFinalAudio: String { abandonedStatus }

    /// Why `replyID`'s audio did not play, or nil.
    public func audioProblem(replyID: String) -> String? {
        presentationStatuses[replyID].flatMap(Self.audioProblem)
    }

    nonisolated static func audioProblem(_ status: String) -> String? {
        switch status {
        case abandonedStatus: audioDidNotArrive
        case playbackFailed, audioFormatNotPlayable, audioCouldNotBeDecoded: audioCouldNotPlay
        default: nil
        }
    }
}

extension ReplyPlaybackController {
    func refuseUnplayableAudio(
        _ audio: AudioPayload, event: HostReplyEvent, descriptor: ReplyDescriptor, key: ReplyStreamKey
    ) -> Bool {
        if audio.codec != .pcm16 || audio.channels != 1 {
            let presentationID = upsertPresentation(event, descriptor: descriptor)
            presentationStatuses[presentationID] = Self.audioFormatNotPlayable
            return true
        }
        // Decode bounds rates and byte size; leave conversion to schedule, once per frame (#825).
        guard audio.bytes.isEmpty || !audio.bytes.count.isMultiple(of: 2) else { return false }
        let presentationID = upsertPresentation(event, descriptor: descriptor)
        failPlayback(for: key)
        presentationStatuses[presentationID] = Self.audioCouldNotBeDecoded
        drain()
        return true
    }

    func failPlayback(for key: ReplyStreamKey) {
        if playbackOrder.contains(key) {
            // The player cannot remove one reply's buffers: its cancel cuts off every entry, even Replay (#825).
            let cancelled = Set(playbackOrder)
            playbackGeneration &+= 1
            player.cancel()
            for interrupted in cancelled {
                let interruptedStatus = streams[interrupted] == nil ? "Replay failed" : Self.playbackFailed
                setPresentationStatus(interruptedStatus, for: interrupted)
                streams[interrupted] = nil
                completed.insert(interrupted)
            }
            queue.removeAll { cancelled.contains($0) }
            playbackOrder.removeAll()
            activeKey = nil
            // The user's pause survives cancellation; drain rebuilds its idle hold (#825).
            idleWatch.cancel?()
            idleWatch.cancel = nil
            idleWatch.key = nil
            idleWatch.aheadUntil = idleNow()
            idleWatch.bufferedUntil = idleNow()
            idleWatch.heldRemaining = nil
        }
        streams[key] = nil
        queue.removeAll { $0 == key }
        completed.insert(key)
        if activeKey == nil {
            status = queue.isEmpty ? (isMuted ? "Muted" : "Ready for replies") : "Waiting for audio"
        }
    }
}
