#if os(macOS)
import Foundation

/// What `switchDuck` did (#735 S-8 HS-C round 2): how many children took it, the privacy entry it opened (nil when
/// none: an off, or an on no child took while privacy was off), and whether privacy was already on.
struct AmbientPrivacyEntry: Sendable {
    let reported: Int
    let entry: Int?
    let wasOn: Bool
}

/// One child's answer for `privacyVerdict`: whether it still hears the stream, and whether a reload swapped it out.
struct AmbientPrivacyChildAnswer {
    let answer: AmbientPrivacyAnswer
    let listening: Bool, replaced: Bool
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

/// Every privacy entry is announced within a bound (#735 S-8 HS-C round 2, Mick: "We should not change state unless
/// we're announcing it."): exactly one of `confirm-privacy-on/` or `confirm-privacy-unavailable/` plays for it.
extension AmbientRightyoRouter {
    /// Twelve seconds: past the ack deadline (5 s) and the start deadline (10 s), so it only ends a wait no deadline
    /// ended. Tests shorten it through the configuration.
    static let privacyConfirmTimeout: TimeInterval = 12

    /// Announces privacy entry `entry` on `connection` once its children answered: kept by every child that still
    /// hears the stream, a reply playing is stopped and `confirm-privacy-on/` plays. Otherwise, while privacy is still
    /// on or a refusal is attributed to this entry, a reply playing is stopped and `confirm-privacy-unavailable/`
    /// plays, the refused child's own `unavailable` held back for it; withdrawn first (an off, which says
    /// "Recording again."), nothing plays. Returns the clip and the log tokens after `on=true`.
    func announceEntry(_ entry: AmbientPrivacyEntry, connection: UUID,
                       listener: WebSocketListener?) async -> (String?, String) {
        let answer = await privacyAnswer(connection: connection)
        let claimed = entry.entry.map { closePrivacyEntry($0, connection: connection) } ?? false
        var (clip, outcome) = Self.announcement(answer, claimed: claimed, on: duckMode(connection: connection),
                                                wasOn: entry.wasOn)
        guard clip != nil else { return (nil, outcome) }
        // Stopped on this chain before the clip is queued, so the stop can never cut the clip.
        outcome += " playback=\(await listener?.stopReplyPlayback(connection: connection) ?? "no_connection")"
        return (clip, outcome)
    }

    /// The entry's clip and log tokens, given its answer, whether it took over a refusal attributed to it (`claimed`),
    /// and whether privacy is still on: `confirm-privacy-on/` when kept, otherwise `confirm-privacy-unavailable/`
    /// unless it was withdrawn with no refusal to say. The two silences are logged, so neither is lost: `withdrawn`
    /// (an off closed it, and "Recording again." is its announcement), and `superseded_by_keep` (a draining or
    /// replaced child's refusal, taken over by an entry every listening child kept).
    static func announcement(_ answer: AmbientPrivacyAnswer, claimed: Bool, on: Bool,
                             wasOn: Bool) -> (String?, String) {
        if answer == .kept {
            let tokens = (wasOn ? " still_on" : "") + (claimed ? " superseded_by_keep" : "")
            return (AmbientStopConfirmation.privacyOn, tokens)
        }
        guard claimed || on else { return (nil, answer == .withdrawn ? " withdrawn" : " withdrawn \(answer.token)") }
        return (AmbientStopConfirmation.privacyUnavailable, " \(answer.token)")
    }

    /// The connection's answer from its children's (#735 S-8 HS-C round 2): a refusal of a child not swapped out
    /// decides it; then privacy off is `withdrawn`; then the children still hearing the stream, those that ended
    /// dropping out: all kept is `kept`, none left is `ended`, else the first that was not kept.
    static func privacyVerdict(_ answers: [AmbientPrivacyChildAnswer], on: Bool) -> AmbientPrivacyAnswer {
        let refusal = answers.first { child in
            guard case .refused = child.answer else { return false }
            return !child.replaced
        }
        if let refusal { return refusal.answer }
        guard on else { return .withdrawn }
        let present = answers.filter { $0.listening && $0.answer != .ended }.map(\.answer)
        return present.first { $0 != .kept } ?? (present.isEmpty ? .ended : .kept)
    }

    /// What `connection`'s privacy came to, within `privacyConfirmTimeout`. Past it, every child whose proof is still
    /// to come is refused, killed and announced as at its own deadline, and the answer is `timeout`.
    func privacyAnswer(connection: UUID) async -> AmbientPrivacyAnswer {
        let timeout = configuration.privacyConfirmTimeout
        let answer = await withTaskGroup(of: AmbientPrivacyAnswer?.self) { group in
            group.addTask { await self.awaitPrivacy(connection: connection) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return Task.isCancelled ? nil : .timeout
            }
            defer { group.cancelAll() }
            while let next = await group.next() {
                if let next { return next }
            }
            return AmbientPrivacyAnswer.timeout
        }
        if answer == .timeout {
            for pipeline in listeningPipelines(connection: connection) { await pipeline.refuseUnproven() }
        }
        return answer
    }

    /// Whether every child of `connection` keeps the privacy wished for (#735 S-8 HS-C), as `privacyAnswer` says.
    func privacyKept(connection: UUID) async -> Bool { await privacyAnswer(connection: connection) == .kept }

    /// Waits for every child that still hears `connection`'s stream, again after each answer, so a child a reload
    /// started meanwhile is waited for too and the answer comes from the children present at the end, never from one
    /// swapped out. A refused child (not swapped out) decides it; a child that ended drops out; with none left, `ended`.
    /// Each answer is read again at the end, so a child refused after it first answered `kept` is not counted kept.
    private func awaitPrivacy(connection: UUID) async -> AmbientPrivacyAnswer {
        var answers: [ObjectIdentifier: (pipeline: RightyoAmbientPipeline, answer: AmbientPrivacyAnswer)] = [:]
        var listening = listeningPipelines(connection: connection)
        while let next = listening.first(where: { answers[ObjectIdentifier($0)] == nil }) {
            let answer = await next.privacyAnswer()
            if Task.isCancelled { return .timeout }
            answers[ObjectIdentifier(next)] = (next, answer)
            listening = listeningPipelines(connection: connection)
        }
        let present = Set(listening.map(ObjectIdentifier.init))
        let children = answers.map { id, child in
            AmbientPrivacyChildAnswer(answer: child.pipeline.privacySettled ?? child.answer,
                                      listening: present.contains(id), replaced: isReplaced(child.pipeline))
        }
        return Self.privacyVerdict(children, on: duckMode(connection: connection))
    }
}
#endif
