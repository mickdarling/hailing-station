import Foundation
import HailProtocol
import OSLog

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
        case pausedAudioNotKept: pausedAudioNotKept
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
            // A refused first update releases its slot; the tombstone prevents ordinary-audio revival.
            if descriptor.sessionUpdateID != nil, streams[key] == nil {
                failPlayback(for: key)
                proactive.identities[key] = nil
            }
            let presentationID = upsertPresentation(event, descriptor: descriptor)
            presentationStatuses[presentationID] = Self.audioFormatNotPlayable
            return true
        }
        // An accepted copy wins: let ingest refuse conflicts without retiring its stream (#825).
        guard streams[key]?.segments[audio.sequence] == nil else { return false }
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
            if isCaptureSuppressed || isPaused {
                status = isCaptureSuppressed ? "Paused while listening" : "Paused"
            } else {
                status = queue.isEmpty ? (isMuted ? "Muted" : "Ready for replies") : "Waiting for audio"
            }
        }
    }
}

/// Limits additional ordinary audio during an owner pause. The paused reply itself is always kept.
struct PausedReplyAudioBudget {
    var seconds: Double = 15 * 60
    var bytes: Int = 64 * 1_024 * 1_024
}

extension ReplyPlaybackController {
    nonisolated static let pausedAudioNotKept = "Audio not kept while paused"
    private static let pausedBudgetLog = Logger(
        subsystem: "com.mickdarling.hailing-station", category: "reply-retention"
    )

    /// Count live streams, including the paused head's scheduled buffers; removal releases their budget.
    var retainedPausedAudio: (bytes: Int, seconds: Double) {
        var retained = streams.values.reduce(into: (bytes: 0, seconds: 0.0)) { total, stream in
            for audio in stream.segments.values {
                total.bytes += audio.bytes.count
                total.seconds += Self.seconds(of: audio)
            }
        }
        // A non-segmented Replay can own the FIFO after its live stream was removed. Its
        // buffers stay in lastAudio until completion lets the next reply enter the player.
        if let activeKey, streams[activeKey] == nil {
            retained.bytes += lastAudio.reduce(0) { $0 + $1.bytes.count }
            retained.seconds += lastAudio.reduce(0) { $0 + Self.seconds(of: $1) }
        }
        return retained
    }

    func retainAudioWhilePaused(
        _ audio: AudioPayload, event: HostReplyEvent, descriptor: ReplyDescriptor, key: ReplyStreamKey
    ) -> Bool {
        if streams[key]?.audioNotKeptWhilePaused == true { return false }
        guard !refuseUnplayableAudio(audio, event: event, descriptor: descriptor, key: key) else { return false }
        // Duplicates/conflicts use normal ingest handling. Session updates retain their existing policy.
        guard isPaused, key != (activeKey ?? queue.first), descriptor.sessionUpdateID == nil,
              streams[key]?.segments[audio.sequence] == nil else { return true }
        let retained = retainedPausedAudio
        guard retained.bytes + audio.bytes.count > pausedAudioBudget.bytes
                || retained.seconds + Self.seconds(of: audio) > pausedAudioBudget.seconds else { return true }
        expiredFirstAudio.remove(key)
        undeliveredLosses.remove(key)
        enqueueStreamIfNeeded(key, descriptor: descriptor)
        var stream = streams[key] ?? ReplyStreamState()
        stream.segments.removeAll() // Release the whole reply; a retained prefix is never playable.
        stream.audioNotKeptWhilePaused = true
        streams[key] = stream
        let id = upsertPresentation(event, descriptor: descriptor)
        presentationStatuses[id] = Self.pausedAudioNotKept
        // Fixed message only: no reply identity, text, endpoint, or audio is logged.
        Self.pausedBudgetLog.notice("Queued reply audio not kept: paused retention budget exceeded")
        return false
    }

    /// Finish text-only entries only when they reach their FIFO turn, after the preceding audio completes.
    func finishTextOnlyPausedHeads() {
        guard !isPaused, !isCaptureSuppressed, activeKey == nil else { return }
        while let key = queue.first, let stream = streams[key],
              stream.audioNotKeptWhilePaused, stream.segments.isEmpty {
            streams[key] = nil
            queue.removeFirst()
            completed.insert(key)
            status = Self.pausedAudioNotKept
        }
    }

    /// Replay eligibility is independent of whether a stream still contains retained storage.
    func retainedReplayAudio(in stream: ReplyStreamState) -> [AudioPayload]? {
        guard !stream.audioNotKeptWhilePaused else { return nil }
        return (0..<stream.nextSequence).compactMap { stream.segments[$0] }
    }

    func nextRetainedSegment(in stream: ReplyStreamState) -> AudioPayload? {
        guard !stream.audioNotKeptWhilePaused else { return nil }
        return stream.segments[stream.nextSequence]
    }
}
