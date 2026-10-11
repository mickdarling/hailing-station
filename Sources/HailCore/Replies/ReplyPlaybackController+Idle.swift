import Foundation
import HailProtocol

/// The head stream's idle watch (#469): when its scheduled audio runs out, and when its last frame came.
struct ReplyIdleWatch {
    var key: ReplyStreamKey?
    var bufferedUntil = ContinuousClock.now
    var lastFrameAt = ContinuousClock.now
    /// While paused or listening nothing plays out: the head's unplayed audio, kept until playback resumes.
    var heldRemaining: Duration?
    var cancel: (@MainActor () -> Void)?
}

extension ReplyPlaybackController {
    /// A stream whose terminal marker never comes (haild crashed, the Mac slept, its request expired mid-reply) would
    /// hold the head of the queue until Stop (#469). Once its scheduled audio has played out and this long passes
    /// with no new frame of its own, it is ended and the queue moves on. A live paced reply stays up to 20 s ahead of
    /// playback and sends a frame every second or so, so its audio never runs out for this long; a slower one is
    /// kept alive by every frame it sends.
    public static let streamIdleTimeout: Duration = .seconds(20)
    nonisolated static let abandonedStatus = "Ended without its final audio"

    /// The default scheduler: a main-actor sleep, cancelled when the watch moves on.
    static func sleepThenFire(
        _ delay: Duration, _ fire: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            fire()
        }
        return { task.cancel() }
    }

    /// The head's segment was handed to the player: its audio now runs out that much later.
    func noteScheduled(_ segment: AudioPayload) {
        let bytesPerSecond = 2 * max(1, segment.sampleRate) * max(1, segment.channels)
        let seconds = Double(segment.bytes.count) / Double(bytesPerSecond)
        idleWatch.bufferedUntil = max(idleNow(), idleWatch.bufferedUntil).advanced(by: .seconds(seconds))
    }

    /// Drains after `key`'s frame arrived; if it is the head's, the head is alive and its timeout starts again.
    func drain(noting key: ReplyStreamKey) {
        drain()
        if queue.first == key { noteHeadFrame() }
    }

    func noteHeadFrame() {
        idleWatch.lastFrameAt = idleNow()
        armIdleWatch()
    }

    /// A new head (or none) starts its own watch; frames of other streams never extend the head's.
    func watchHeadIfChanged() {
        syncIdleHold()
        guard queue.first != idleWatch.key else { return }
        idleWatch.key = queue.first
        idleWatch.bufferedUntil = idleNow()
        idleWatch.lastFrameAt = idleNow()
        idleWatch.heldRemaining = isPaused || isCaptureSuppressed ? .zero : nil
        armIdleWatch()
    }

    /// Paused or listening, the player holds its audio (Codex P1 on #473): the head's unplayed duration is kept
    /// and the watch stops, then it resumes with that duration still to play, so a pause never ends a stream early.
    func syncIdleHold() {
        let held = isPaused || isCaptureSuppressed
        if held, idleWatch.heldRemaining == nil {
            idleWatch.heldRemaining = max(.zero, idleNow().duration(to: idleWatch.bufferedUntil))
            idleWatch.cancel?()
            idleWatch.cancel = nil
        } else if !held, let remaining = idleWatch.heldRemaining {
            idleWatch.heldRemaining = nil
            idleWatch.bufferedUntil = idleNow().advanced(by: remaining)
            armIdleWatch()
        }
    }

    func armIdleWatch() {
        idleWatch.cancel?()
        idleWatch.cancel = nil
        // A head whose final segment is scheduled has ended its stream: only the player's completion moves it on,
        // however long the player stalls, so a finished reply is never relabelled or unmasked (#473 review).
        guard let key = queue.first, key == idleWatch.key, idleWatch.heldRemaining == nil,
              !completed.contains(key) else { return }
        let deadline = max(idleWatch.bufferedUntil, idleWatch.lastFrameAt).advanced(by: Self.streamIdleTimeout)
        let delay = max(.zero, idleNow().duration(to: deadline))
        idleWatch.cancel = idleScheduler(delay) { [weak self] in self?.idleDeadlinePassed(for: key) }
    }

    func idleDeadlinePassed(for key: ReplyStreamKey) {
        guard queue.first == key, idleWatch.key == key, !completed.contains(key) else { return }
        let deadline = max(idleWatch.bufferedUntil, idleWatch.lastFrameAt).advanced(by: Self.streamIdleTimeout)
        guard idleNow() >= deadline else { return armIdleWatch() }
        guard !isPaused, !isCaptureSuppressed else { return syncIdleHold() }
        abandonHead(key)
    }

    /// Ends the stuck head as if it had finished. The player is not cancelled: anything still buffered plays out,
    /// and the next reply follows it. Later frames of the abandoned stream are ignored.
    private func abandonHead(_ key: ReplyStreamKey) {
        setPresentationStatus(Self.abandonedStatus, for: key)
        rollbackPlaybackStart(for: key)
        streams[key] = nil
        queue.removeFirst()
        completed.insert(key)
        drain()
        trimPresentations()
        if activeKey == nil {
            status = queue.isEmpty ? (isMuted ? "Muted" : "Played") : "Waiting for audio"
        }
    }
}
