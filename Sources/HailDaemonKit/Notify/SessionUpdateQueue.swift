public import Foundation

/// What the host does with a submitted update (#609).
public enum SessionUpdateDecision: Sendable, Equatable {
    /// Speak it now on this listening device. Not held: if delivery fails, the caller passes it to
    /// `hold(_:audience:at:)`, which decides the push afresh.
    case speak(SessionUpdate, device: UUID)
    /// Held for a later drain; `push` names the device to send a push notification to, if any.
    case held(push: UUID?)
    case refused(SessionUpdateRefusal)
}

public enum SessionUpdateRefusal: Sendable, Equatable {
    /// Unsolicited updates are off (the default).
    case disabled
    /// This session has used its budget; it may try again after the given time.
    case rateLimited(retryAfter: Duration)
    /// Every held slot is an `action` update the user has not heard yet.
    case full
    /// The update is older than the policy's lifetime; it would be dropped unspoken.
    case expired
}

/// What offered a drain of the held updates.
public enum SessionUpdateDrainTrigger: Sendable, Equatable {
    /// A pause in the conversation on a listening device.
    case naturalPause
    /// The user asked, for example "any updates?".
    case asked
    /// The user spoke to or used a device.
    case interaction
}

/// The policy and queue for sessions' unsolicited updates (#609): pure, value semantics, no I/O, no clock of its
/// own. The caller passes the time and an audience snapshot; the result says whom to speak to, push, or hold.
///
/// Rules:
/// - `info` is always held, and spoken at the next natural pause, when the user asks, or at the next interaction.
/// - `action` is spoken now when a device is listening and neither quiet nor media mode is on. Otherwise it is held
///   and pushed to the target device, except under quiet, which holds it without a push.
/// - Drains: asking always delivers. An interaction delivers unless quiet is on. A natural pause delivers unless
///   quiet or media mode is on.
/// - Each session has its own budget per window; refusals do not spend it. The session name is the budget key and
///   the speaker label, so the caller must take it from an authenticated source (the registry's target id), never
///   from text the caller supplied.
public struct SessionUpdateQueue: Sendable, Equatable {
    public typealias Instant = ContinuousClock.Instant

    public var policy: SessionUpdatePolicy
    public private(set) var held: [SessionUpdate] = []
    private var sent: [String: [Instant]] = [:]

    public init(policy: SessionUpdatePolicy = .init()) { self.policy = policy }

    public mutating func submit(
        _ update: SessionUpdate, audience: SessionUpdateAudience, now: Instant
    ) -> SessionUpdateDecision {
        guard policy.enabled else { return .refused(.disabled) }
        expire(now: now)
        if let wait = retryAfter(session: update.session, now: now) { return .refused(.rateLimited(retryAfter: wait)) }
        if update.priority == .action, let device = audience.listeningDevice, !audience.quiet, !audience.media {
            spend(update.session, at: now)
            return .speak(update, device: device)
        }
        guard keep(update, now: now) else { return .refused(.full) }
        spend(update.session, at: now)
        return .held(push: Self.push(update, audience: audience))
    }

    /// Holds an update without spending budget, for one whose immediate speech failed. The push follows the same
    /// rule as `submit`, from the audience now: an `action` is pushed to the target unless quiet is on. Idempotent
    /// per update id: holding one already held keeps one copy and pushes nothing again. An expired update is refused.
    public mutating func hold(
        _ update: SessionUpdate, audience: SessionUpdateAudience, at now: Instant
    ) -> SessionUpdateDecision {
        guard policy.enabled else { return .refused(.disabled) }
        expire(now: now)
        guard update.submitted.duration(to: now) < policy.lifetime else { return .refused(.expired) }
        guard !held.contains(where: { $0.id == update.id }) else { return .held(push: nil) }
        guard keep(update, now: now) else { return .refused(.full) }
        return .held(push: Self.push(update, audience: audience))
    }

    private static func push(_ update: SessionUpdate, audience: SessionUpdateAudience) -> UUID? {
        update.priority == .action && !audience.quiet ? audience.target : nil
    }

    private mutating func keep(_ update: SessionUpdate, now: Instant) -> Bool {
        expire(now: now)
        guard !held.contains(where: { $0.id == update.id }) else { return true }
        if held.count >= max(policy.capacity, 0) {
            // The oldest info by submit time goes first, the earliest held among equals: the drain order.
            guard let oldest = held.indices.filter({ held[$0].priority == .info })
                .min(by: { held[$0].submitted < held[$1].submitted }) else { return false }
            held.remove(at: oldest)
        }
        guard held.count < policy.capacity else { return false }
        held.append(update)
        return true
    }

    /// The held updates to deliver now, `action` first and then by submit time (not hold time, so a failed `action`
    /// held again keeps its place), removed from the queue. Empty when
    /// the trigger is not allowed under the audience's quiet or media state.
    public mutating func drain(
        _ trigger: SessionUpdateDrainTrigger, audience: SessionUpdateAudience, now: Instant
    ) -> [SessionUpdate] {
        expire(now: now)
        switch trigger {
        case .asked: break
        case .interaction: guard !audience.quiet else { return [] }
        case .naturalPause: guard !audience.quiet, !audience.media else { return [] }
        }
        let ordered = held.enumerated().sorted { left, right in
            let (lhs, rhs) = (left.element, right.element)
            if lhs.priority != rhs.priority { return lhs.priority == .action }
            return lhs.submitted != rhs.submitted ? lhs.submitted < rhs.submitted : left.offset < right.offset
        }.map(\.element)
        held.removeAll()
        return ordered
    }

    /// One spoken line for a drain: "Voice Work: The deck is built." for one update, and a count first for more.
    public static func digest(_ updates: [SessionUpdate]) -> String? {
        let lines = updates.map { "\($0.session): \(sentence($0.spoken))" }
        guard let first = lines.first else { return nil }
        return lines.count == 1 ? first : "You have \(lines.count) updates. " + lines.joined(separator: " ")
    }

    /// Time until `session` may send again, or nil when it may send now. A nonpositive limit refuses for a window.
    public func retryAfter(session: String, now: Instant) -> Duration? {
        guard policy.perSessionLimit > 0 else { return policy.window }
        let recent = (sent[session] ?? []).filter { $0.duration(to: now) < policy.window }.sorted()
        guard recent.count >= policy.perSessionLimit else { return nil }
        let blocking = recent[recent.count - policy.perSessionLimit]
        return max(.zero, policy.window - blocking.duration(to: now))
    }

    private mutating func spend(_ session: String, at now: Instant) {
        sent[session, default: []].append(now)
        for (key, stamps) in sent {
            let kept = stamps.filter { $0.duration(to: now) < policy.window }
            sent[key] = kept.isEmpty ? nil : kept
        }
    }

    private mutating func expire(now: Instant) {
        held.removeAll { $0.submitted.duration(to: now) >= policy.lifetime }
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }
}
