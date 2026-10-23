/// How long a stalled reply waits before it plays on (#825, Mick: "if there's a problem, you can pick up more smoothly
/// afterwards"). A reply always starts the moment its first audio arrives; this target applies only after the queued
/// audio ran dry mid-reply. Each stall raises it a step, for the rest of that reply and the next ones, and replies
/// that play through cleanly lower it again a step at a time.
public struct ReplyPlayoutPolicy: Equatable, Sendable {
    public static let steps: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
    /// Clean replies in a row that lower the target one step.
    public static let cleanRepliesPerStep = 3

    /// Audio queued ahead before a stalled reply plays on; zero until the first stall.
    public var target: Duration { step < 0 ? .zero : Self.steps[step] }
    private var step = -1
    private var cleanReplies = 0
    private var stalledThisReply = false

    public init() {}

    /// A new reply: whether it stalls is its own.
    mutating func replyStarted() { stalledThisReply = false }

    mutating func stalled() {
        step = min(step + 1, Self.steps.count - 1)
        stalledThisReply = true
        cleanReplies = 0
    }

    mutating func replyEnded() {
        defer { stalledThisReply = false }
        guard !stalledThisReply, step >= 0 else { return }
        cleanReplies += 1
        guard cleanReplies >= Self.cleanRepliesPerStep else { return }
        step -= 1
        cleanReplies = 0
    }
}

/// The reply player's view of what it has queued (#825). Audio plays as it arrives; when the queue runs dry before a
/// reply's final audio, the player holds (catching up) instead of playing each late frame the moment it lands, which
/// is the stutter. It plays on once the audio queued ahead reaches the policy's target, or the final audio is in.
/// Pure, so it is tested without an audio engine.
public struct ReplyPlayoutBuffer: Equatable, Sendable {
    public private(set) var policy = ReplyPlayoutPolicy()
    /// Holding a stalled reply until enough audio is queued ahead.
    public private(set) var isCatchingUp = false
    /// Audio queued and not yet played.
    public private(set) var ahead: Duration = .zero
    private var outstanding = 0
    private var finalQueued = false

    public init() {}

    /// Buffers of `durations` were queued; `startsReply` for a reply's first audio, `endsReply` for its last.
    /// Returns true when the player should be playing: always for a new reply, which never waits.
    public mutating func queued(_ durations: [Duration], startsReply: Bool, endsReply: Bool) -> Bool {
        if startsReply {
            (isCatchingUp, finalQueued) = (false, false)
            policy.replyStarted()
        }
        outstanding += durations.count
        ahead += durations.reduce(.zero, +)
        if endsReply { finalQueued = true }
        if isCatchingUp, finalQueued || ahead >= policy.target { isCatchingUp = false }
        return !isCatchingUp
    }

    /// One queued buffer of `duration` finished playing. Returns true when that ran the queue dry before the
    /// reply's final audio: a stall, after which the player holds until it catches up.
    public mutating func played(_ duration: Duration) -> Bool {
        guard outstanding > 0 else { return false } // A completion from before a clear.
        outstanding -= 1
        ahead = outstanding == 0 ? .zero : max(.zero, ahead - duration)
        guard outstanding == 0 else { return false }
        if finalQueued {
            finalQueued = false
            policy.replyEnded()
            return false
        }
        guard !isCatchingUp else { return false }
        isCatchingUp = true
        policy.stalled()
        return true
    }

    /// The queue was dropped (a stop, a replay, a route change): nothing is held, and the policy is kept.
    public mutating func cleared() {
        (isCatchingUp, ahead, outstanding, finalQueued) = (false, .zero, 0, false)
    }
}

/// A reply player that holds a stalled reply until it catches up (#825), and says when, so status stays honest.
@MainActor
public protocol ReplyCatchUpReporting: AnyObject {
    var onCatchingUpChanged: (@MainActor (Bool) -> Void)? { get set }
}

extension ReplyPlaybackController {
    static let catchingUpStatus = "Catching up…"

    /// The status says when a stalled reply is held to catch up (#825), and goes back to playing when it plays on.
    func observeCatchUp() {
        (player as? any ReplyCatchUpReporting)?.onCatchingUpChanged = { [weak self] in self?.catchingUpChanged($0) }
    }

    func catchingUpChanged(_ catchingUp: Bool) {
        guard let key = activeKey else { return }
        if catchingUp {
            status = Self.catchingUpStatus
            setPresentationStatus(Self.catchingUpStatus, for: key)
        } else if status == Self.catchingUpStatus {
            status = isMuted ? "Muted" : "Playing"
            setPresentationStatus(nil, for: key)
        }
    }
}
