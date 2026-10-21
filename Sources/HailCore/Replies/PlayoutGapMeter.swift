/// Audible gaps while replies play (#737). The player queues reply audio as it arrives and plays it at once, with
/// no reserve, so a frame that arrives after the queued audio ran out leaves silence mid-reply. This counts those
/// gaps against the wall clock: each scheduled buffer extends when the queue runs dry, and a buffer scheduled after
/// that point, within a reply, is a gap of the difference. A reply's first audio never counts, and a gap shorter
/// than `threshold` is scheduling noise, not something heard.
public struct PlayoutGapMeter: Equatable, Sendable {
    public struct Gaps: Equatable, Sendable {
        public var count = 0
        public var total: Duration = .zero
        public var milliseconds: Int64 { Int64(total / .milliseconds(1)) }
    }

    public static let threshold: Duration = .milliseconds(20)

    public private(set) var gaps = Gaps()
    private var queuedUntil: ContinuousClock.Instant?
    private var pausedWith: Duration?

    public init() {}

    /// `duration` of audio was queued at `now`; `startsReply` for a reply's first audio.
    public mutating func scheduled(_ duration: Duration, at now: ContinuousClock.Instant, startsReply: Bool) {
        if !startsReply, pausedWith == nil, let queuedUntil, now - queuedUntil >= Self.threshold {
            gaps.count += 1
            gaps.total += now - queuedUntil
        }
        if let remaining = pausedWith {
            pausedWith = remaining + duration
        } else {
            queuedUntil = max(queuedUntil ?? now, now) + duration
        }
    }

    /// Playback paused at `now`: what is still queued waits, and time paused is never a gap.
    public mutating func paused(at now: ContinuousClock.Instant) {
        guard pausedWith == nil else { return }
        pausedWith = queuedUntil.map { max(.zero, $0 - now) } ?? .zero
    }

    /// Playback resumed at `now` with whatever was queued when it paused.
    public mutating func resumed(at now: ContinuousClock.Instant) {
        guard let remaining = pausedWith else { return }
        pausedWith = nil
        queuedUntil = now + remaining
    }

    /// The queue was dropped (a stop, or a new queue): the next audio starts afresh.
    public mutating func cleared() {
        (queuedUntil, pausedWith) = (nil, nil)
    }

    /// The gaps counted since the last call, which starts a new count.
    public mutating func take() -> Gaps {
        defer { gaps = Gaps() }
        return gaps
    }
}

/// A reply player that counts its audible gaps (#737).
@MainActor
public protocol PlayoutGapReporting: AnyObject {
    /// The gaps counted since the last call, which starts a new count.
    func takePlayoutGaps() -> PlayoutGapMeter.Gaps
}
