#if os(macOS)
import Foundation

/// What `switchDuck` did (#735 S-8 HS-C round 2): how many children took it, the privacy entry it opened (nil when
/// none: an off, or an on no child took while privacy was off), whether privacy was already on, and when it opened
/// (round 3: its bound runs from then, not from when the clip chain reaches it).
struct AmbientPrivacyEntry: Sendable {
    let reported: Int
    let entry: Int?
    let wasOn: Bool
    var opened = ContinuousClock.now
}

/// One child's answer for `privacyVerdict`, read at the entry's close (round 3): whether it still hears the stream,
/// whether it was retired (a reload swapped it out, or it drains: it hears nothing more), whether the close claimed its
/// refusal, and whether the bound refused it.
struct AmbientPrivacyChildAnswer {
    let answer: AmbientPrivacyAnswer
    let listening: Bool, retired: Bool
    var claimed = false, refusedAtBound = false
}

/// One child an entry was opened on, as its close sees it.
struct AmbientPrivacyEntryChild {
    let duck: AmbientDuckControl
    let listening: Bool
}

/// An entry's close and verdict (round 3): the answer, whether it says a refusal it claimed, and the children the bound
/// refused (to be killed).
struct AmbientPrivacyDecision {
    let answer: AmbientPrivacyAnswer
    let claimed: Bool
    let refused: [RightyoAmbientPipeline]
}

extension AmbientPrivacyAnswer {
    /// The entry's log token for an answer other than `kept`: `unacknowledged` only for an ack deadline.
    var token: String {
        switch self {
        case .kept: "kept"
        case .refused(.unacknowledged): "unacknowledged"
        case .refused: "refused"
        case .ended: "ended"
        case .withdrawn: "withdrawn"
        case .timeout: "timeout"
        }
    }
}

/// Every privacy entry is announced within a bound (#735 S-8 HS-C, Mick: "We should not change state unless we're
/// announcing it."): exactly one of `confirm-privacy-on/` or `confirm-privacy-unavailable/` plays for it, on the
/// connection's one clip chain (round 3), or, only when an off withdrew it, nothing (logged `withdrawn`).
extension AmbientRightyoRouter {
    /// The margin past a child's start and ack deadlines (round 3): the bound is start + ack + this (16 s by default),
    /// so it only ends a wait no deadline ended, even for a child that starts just before its start deadline.
    static let privacyConfirmMargin: TimeInterval = 1

    /// Announces privacy entry `entry` on `connection` (round 3): waits within the bound for every child that still
    /// hears the stream, then closes the entry and reads each child's answer in that one step (`closePrivacyEntry`),
    /// so a refusal after it is the child's own, said after this clip on the same chain. Kept by every listening
    /// child: a reply playing is stopped and `confirm-privacy-on/` plays. Withdrawn by an off ("Recording again."):
    /// nothing, unless it claimed a refusal. Otherwise the stop, then `confirm-privacy-unavailable/`. Returns the clip
    /// and the log tokens after `on=true`. Runs on the connection's clip chain.
    func announceEntry(_ entry: AmbientPrivacyEntry, connection: UUID,
                       listener: WebSocketListener?) async -> (String?, String) {
        guard let number = entry.entry else { return (nil, " withdrawn") }
        let decision = await decideEntry(number, connection: connection, opened: entry.opened)
        for pipeline in decision.refused { await pipeline.killRefused() }
        var (clip, outcome) = Self.announcement(decision.answer, claimed: decision.claimed, wasOn: entry.wasOn)
        guard clip != nil else { return (nil, outcome) }
        // Stopped on this chain right before the clip is queued, so the stop can never cut the clip.
        outcome += " playback=\(await listener?.stopReplyPlayback(connection: connection) ?? "no_connection")"
        return (clip, outcome)
    }

    /// The entry's clip and log tokens, given its answer, whether it says a refusal it claimed, and whether privacy was
    /// already on: `confirm-privacy-on/` when kept (`superseded_by_keep` only for a draining or replaced child's
    /// refusal: the verdict counts any other), nothing when withdrawn with no refusal to say, else `confirm-privacy-unavailable/`.
    static func announcement(_ answer: AmbientPrivacyAnswer, claimed: Bool, wasOn: Bool) -> (String?, String) {
        switch answer {
        case .kept:
            return (AmbientStopConfirmation.privacyOn,
                    (wasOn ? " still_on" : "") + (claimed ? " superseded_by_keep" : ""))
        case .withdrawn:
            return claimed ? (AmbientStopConfirmation.privacyUnavailable, " withdrawn claimed") : (nil, " withdrawn")
        default:
            return (AmbientStopConfirmation.privacyUnavailable, " \(answer.token)")
        }
    }

    /// The entry's answer from its children's at the close (round 3): withdrawn by an off; `timeout` when the bound
    /// refused one; then a refusal of a child not retired (one that listened to the end, even once its run is gone;
    /// a draining or replaced child hears nothing more, so its refusal is its own, or `superseded_by_keep`); then a
    /// refused start the entry claimed; then the listening children, those that ended dropping out: all kept is
    /// `kept`, none left is `ended`, else the first that was not. Belt and braces (key 1): never `kept` while a claimed
    /// child that was not retired is counted.
    static func privacyVerdict(_ answers: [AmbientPrivacyChildAnswer], withdrawn: Bool,
                               startRefused: Bool = false) -> AmbientPrivacyAnswer {
        if withdrawn { return .withdrawn }
        if answers.contains(where: \.refusedAtBound) { return .timeout }
        let refusal = answers.first { child in
            guard case .refused = child.answer else { return false }
            return !child.retired
        }
        if let refusal { return refusal.answer }
        if startRefused || answers.contains(where: { $0.claimed && !$0.retired }) { return .refused(nil) }
        let present = answers.filter { $0.listening && $0.answer != .ended }.map(\.answer)
        return present.first { $0 != .kept } ?? (present.isEmpty ? .ended : .kept)
    }

    /// Closes entry `entry` on its children (round 3), or nil, closing nothing, while a listening child's proof is
    /// still to come and neither the bound nor an off has ended the wait. Each child is closed and read in one step
    /// under its lock; with `timedOut`, a proof still to come is refused there (the ack or the bound, whichever came
    /// first). The caller holds the router's lock, so no child registers or is swapped out meanwhile.
    static func closeEntry(_ entry: Int, children: [AmbientPrivacyEntryChild], withdrawn: Bool,
                           timedOut: Bool) -> [(AmbientPrivacyChildAnswer, refused: Bool)]? {
        if !withdrawn, !timedOut, children.contains(where: { $0.listening && $0.duck.settled == nil }) { return nil }
        return children.map { child in
            let closing = child.duck.close(entry: entry, refusePending: timedOut && !withdrawn && child.listening)
            let answer = AmbientPrivacyChildAnswer(answer: closing.answer ?? .timeout, listening: child.listening,
                                                   retired: closing.retired, claimed: closing.claimed,
                                                   refusedAtBound: closing.refused)
            return (answer, closing.refused)
        }
    }

    /// Waits for entry `entry` within the bound, start + ack + margin from its opening, then closes it
    /// (`closePrivacyEntry`); a child a reload registered meanwhile, still to prove, sends it back to waiting.
    private func decideEntry(_ entry: Int, connection: UUID,
                             opened: ContinuousClock.Instant) async -> AmbientPrivacyDecision {
        let deadline = opened.advanced(by: .seconds(configuration.privacyBound))
        while true {
            let timedOut = await waitForPrivacy(entry, connection: connection, until: deadline)
            if let decision = closePrivacyEntry(entry, connection: connection, timedOut: timedOut) { return decision }
        }
    }

    /// True when the bound passed before every listening child answered (or an off withdrew the entry).
    private func waitForPrivacy(_ entry: Int, connection: UUID, until deadline: ContinuousClock.Instant) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.awaitSettled(entry, connection: connection)
                return false
            }
            group.addTask {
                try? await Task.sleep(until: deadline)
                return !Task.isCancelled
            }
            defer { group.cancelAll() }
            return await group.next() ?? true
        }
    }

    /// Waits until every child that still hears `connection`'s stream has answered, again after each answer, so a
    /// child a reload started meanwhile is waited for too; or until an off withdrew `entry`; or cancellation.
    private func awaitSettled(_ entry: Int?, connection: UUID) async {
        while !Task.isCancelled, !(entry.map { privacyWithdrawn($0, connection: connection) } ?? false),
              let next = listeningPipelines(connection: connection).first(where: { $0.privacySettled == nil }) {
            _ = await next.privacyAnswer()
        }
    }

    /// Whether every child that hears `connection`'s stream keeps the privacy wished for, once each answered (tests).
    func privacyKept(connection: UUID) async -> Bool {
        await awaitSettled(nil, connection: connection)
        let pipelines = listeningPipelines(connection: connection)
        return !pipelines.isEmpty && pipelines.allSatisfy { $0.privacySettled == .kept }
    }
}
#endif
