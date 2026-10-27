public import Foundation
import HailProtocol

/// Device settings, v1, pending Mick. Seconds; no spoken "go on" resume in v1.
public struct ReplySegmentSettings: Equatable, Sendable {
    public static let defaultsKey = "hailing-station.reply-segments.v1"
    public let pauseAfterSegment: TimeInterval
    public let sustainedOnset: TimeInterval

    /// Invalid/nonfinite values fall back individually. A pause is 0.1–10 s; onset is 0.05–2 s.
    public init(pauseAfterSegment: TimeInterval = 1.5, sustainedOnset: TimeInterval = 0.3) {
        self.pauseAfterSegment = (0.1...10).contains(pauseAfterSegment) ? pauseAfterSegment : 1.5
        self.sustainedOnset = (0.05...2).contains(sustainedOnset) ? sustainedOnset : 0.3
    }

    public static func saved(in defaults: UserDefaults = .standard) -> Self {
        let values = defaults.dictionary(forKey: defaultsKey)
        return Self(pauseAfterSegment: values?["pauseAfterSegment"] as? Double ?? 1.5,
                    sustainedOnset: values?["sustainedOnset"] as? Double ?? 0.3)
    }

    public func save(in defaults: UserDefaults = .standard) {
        let values = ["pauseAfterSegment": pauseAfterSegment, "sustainedOnset": sustainedOnset]
        defaults.set(values, forKey: Self.defaultsKey)
    }
}

/// Bounded, content-free state for P4b/P5; segment counts only marker frames that finished playback.
public struct ReplySegmentPause: Equatable, Sendable {
    public let endpointID: HostEndpoint.Identifier
    public let replyID: UUID
    public let segment: Int
}

/// A flushed marker did not play. Engine/route resets must retire its barrier, never open a voice window.
@MainActor
protocol ReplySegmentDiscardReporting: AnyObject {
    var onSegmentDiscarded: (@MainActor () -> Void)? { get set }
}

extension ReplyPlaybackController {
    func observeSegmentDiscards() {
        let reporter = player as? any ReplySegmentDiscardReporting
            ?? (player as? EchoGuardedReplyPlayer)?.gapReporter as? any ReplySegmentDiscardReporting
        reporter?.onSegmentDiscarded = { [weak self] in
            guard let self, let key = segmentBoundary else { return }
            let generation = playbackGeneration
            // A caller's own stop/cancel completes first. Only an otherwise unhandled engine reset retires here.
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackGeneration, self.segmentBoundary == key else { return }
                self.failPlayback(for: key)
                self.drain()
            }
        }
    }

    private func finished(_ key: ReplyStreamKey, generation: UInt) -> @MainActor @Sendable () -> Void {
        { [weak self] in self?.playbackFinished(key, generation: generation) }
    }

    func completion(
        for audio: AudioPayload, key: ReplyStreamKey, generation: UInt
    ) -> (@MainActor @Sendable () -> Void)? {
        if audio.isFinal { return finished(key, generation: generation) }
        guard audio.isSegmentEnd else { return nil }
        segmentBoundary = key
        segmentBoundarySequence = audio.sequence
        return { [weak self] in self?.segmentPlayed(key, sequence: audio.sequence, generation: generation) }
    }

    private func segmentPlayed(_ key: ReplyStreamKey, sequence: Int, generation: UInt) {
        guard generation == playbackGeneration, segmentBoundary == key,
              segmentBoundarySequence == sequence, segmentPause == nil else { return }
        segmentBoundarySequence = nil
        idleWatch.heldRemaining = .zero // The marker and everything before it have actually played.
        playedSegmentEnds = min(playedSegmentEnds + 1, ReplySegments.maxSegmentEnds)
        segmentPause = ReplySegmentPause(endpointID: key.endpointID, replyID: key.replyID, segment: playedSegmentEnds)
        syncIdleHold()
        cancelSegmentPause = idleScheduler(.seconds(segmentSettings.pauseAfterSegment)) { [weak self] in
            guard let self, generation == playbackGeneration, segmentBoundary == key else { return }
            segmentPause = nil
            segmentBoundary = nil
            cancelSegmentPause = nil
            // Intentional silence is excluded from both the buffered-audio and frame-arrival deadlines.
            idleWatch.lastFrameAt = idleNow()
            syncIdleHold()
            drain()
        }
    }

    func clearSegmentBoundary() {
        cancelSegmentPause?()
        cancelSegmentPause = nil
        segmentPause = nil
        segmentBoundary = nil
        segmentBoundarySequence = nil
        playedSegmentEnds = 0
    }

    /// Callable foundation only: P4b supplies fresh ambient/privacy state and handles transport/mask release.
    /// No audio is accepted, retained or replayed here (v1 choice B: lose onset audio).
    @discardableResult
    public func yieldPausedReply(ambientListening: Bool, privacyOn: Bool) -> ReplySegmentPause? {
        guard ambientListening, !privacyOn, let pause = segmentPause, let key = segmentBoundary,
              activeKey == key else { return nil }
        player.cancel()
        playbackGeneration &+= 1
        streams[key] = nil
        completed.insert(key)
        queue.removeAll { $0 == key }
        playbackOrder.removeAll { $0 == key }
        activeKey = playbackOrder.first
        setPresentationStatus("Yielded", for: key)
        lastSegmentYield = pause
        drain()
        return pause
    }
}
/// The head stream's idle watch (#469): when its scheduled audio runs out, and when its last frame came.
struct ReplyIdleWatch {
    var key: ReplyStreamKey?
    var bufferedUntil = ContinuousClock.now
    var lastFrameAt = ContinuousClock.now
    /// Audio the player plays before the head's: a replay (Codex P1 on #473). The head's audio starts after it.
    var aheadUntil = ContinuousClock.now
    var audioInterrupted = false
    /// While paused, listening or interrupted nothing plays out: the unplayed audio, kept until playback resumes.
    var heldRemaining: Duration?
    var cancel: (@MainActor () -> Void)?
}
extension ReplyPlaybackController {
    static func sleepThenFire(
        _ delay: Duration, _ fire: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            fire()
        }
        return { task.cancel() }
    }
}
