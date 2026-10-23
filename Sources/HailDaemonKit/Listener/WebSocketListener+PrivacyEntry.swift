#if os(macOS)
import Foundation

/// What `switchDuck` did (#735 S-8 HS-C round 2): how many children took it, the privacy entry it opened (nil when
/// none: an off, or an on no child took while privacy was off), whether privacy was already on, and whether it is on
/// now (round 4: read under the lock that decided it, where its clip is queued too).
struct AmbientPrivacyEntry: Sendable {
    let reported: Int
    let entry: Int?
    let wasOn: Bool
    var on = false
}

/// One child's answer for `privacyVerdict`, read at the entry's close: whether it still hears the stream (round 4:
/// the only exemption; a child that drains, was swapped out or is gone hears nothing), whether the close claimed its
/// refusal, and whether its bound refused it.
struct AmbientPrivacyChildAnswer {
    let answer: AmbientPrivacyAnswer
    let listening: Bool
    var claimed = false, refusedAtBound = false
}

/// The owner's last word on a connection's privacy, as decided (round 4): the clip chain plays in that order.
enum AmbientPrivacySaid: Equatable, Sendable { case on, unavailable, off }

/// An entry's close (round 4): its clip (nil: a logged silence), its log tokens, the children whose refusal it took
/// over, and those their bound refused (to be killed).
struct AmbientPrivacyDecision<Child: AnyObject> {
    let clip: String?
    let tokens: String
    var claimed: [Child] = [], refused: [Child] = []
}

/// Still to wait (until the earliest listening child's own bound), or decided.
enum AmbientPrivacyClose<Child: AnyObject> {
    case wait(until: Double)
    case decided(AmbientPrivacyDecision<Child>)
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

/// One connection's privacy entries and last word (#735 S-8 HS-C round 4), a value the router keeps under its lock and
/// the property test drives directly, so both run the same decisions: opening, a child registering, an off, a refusal,
/// and the close. Times are seconds on the caller's clock; `bound` is start + ack + margin.
struct AmbientPrivacyLedger<Child: AnyObject> {
    /// A child an entry is open on, and when it was opened on it (the entry's opening, or the child's registration).
    struct Member {
        let child: Child, duck: AmbientDuckControl, opened: Double
    }
    struct Entry {
        let opened: Double, wasOn: Bool
        var members: [Member]
        /// An off withdrew it; a refusal another place would have said is carried to it.
        var withdrawn = false, carried = false
    }
    private(set) var entries: [Int: Entry] = [:]
    private(set) var last = 0
    /// The last clip decided for this connection's privacy state, nil before any.
    private(set) var said: AmbientPrivacySaid?

    /// Opens the next entry on `children` (every child of the connection) at `now`.
    mutating func open(on children: [(Child, AmbientDuckControl)], wasOn: Bool, at now: Double) -> Int {
        last += 1
        children.forEach { $0.1.open(entry: last) }
        entries[last] = Entry(opened: now, wasOn: wasOn, members: children.map {
            Member(child: $0.0, duck: $0.1, opened: now)
        })
        return last
    }

    /// A child registered at `now` (a new stream or a reload): every open entry opens on it, its wait bounded from
    /// now. While private with nothing open and "unavailable" the last word, it may restore privacy, so a recovery
    /// entry opens on every child (`all`) and its number is returned: never a silent change of state.
    mutating func register(_ child: Child, duck: AmbientDuckControl, at now: Double, on: Bool,
                           all: [(Child, AmbientDuckControl)]) -> Int? {
        for key in entries.keys {
            duck.open(entry: key)
            entries[key]?.members.append(Member(child: child, duck: duck, opened: now))
        }
        guard on, entries.isEmpty, said == .unavailable else { return nil }
        return open(on: all, wasOn: true, at: now)
    }

    /// An off: every open entry is withdrawn, and "Recording again." is the last word.
    mutating func withdrawAll() {
        for key in entries.keys { entries[key]?.withdrawn = true }
        said = .off
    }

    /// The state rule for a refusal (`duck`, or nil for a start refused while private): whether `unavailable` is said
    /// now, else the log token. Said only when it changed the owner's state: never twice, never after an off, never
    /// while an open entry (the newest announces it, carried) or a listening child (`holders`) still keeps privacy.
    mutating func refusal(of duck: AmbientDuckControl?, on: Bool, holders: [AmbientDuckControl]) -> (Bool, String?) {
        if let duck, !duck.takeAnnouncement() { return (false, "unavailable=said_by_entry") }
        guard on else { return (false, duck == nil ? nil : "unavailable=superseded_by_off") }
        if let newest = entries.filter({ !$0.value.withdrawn }).keys.max() {
            entries[newest]?.carried = true
            return (false, "unavailable=said_by_entry carried")
        }
        if holders.contains(where: \.holdsPrivacy) { return (false, "unavailable=superseded_by_keep") }
        said = .unavailable
        return (true, nil)
    }

    /// Closes `entry` at `now`, or says how long to wait: while a listening child's proof is still to come within its
    /// own bound (its open + `bound`), unless an off withdrew the entry or a newer one is open. Each child is closed
    /// and read in one step under its lock; one past its own bound is refused there (the ack or the bound, whichever
    /// came first). An older entry closing under a newer one says nothing (`superseded_by_newer`) and carries any
    /// refusal it claimed to the newest, which announces the outcome.
    mutating func close(_ entry: Int, now: Double, bound: Double,
                        listening: (Child) -> Bool) -> AmbientPrivacyClose<Child> {
        guard let state = entries[entry] else { return .decided(.init(clip: nil, tokens: " withdrawn")) }
        let newest = entries.keys.max() ?? entry
        let deciding = !state.withdrawn && newest == entry
        let hears = state.members.map { listening($0.child) }
        let waits = zip(state.members, hears).filter { member, hears in
            hears && member.duck.settled == nil && now < member.opened + bound
        }
        if deciding, let until = waits.map({ $0.0.opened + bound }).min() { return .wait(until: until) }
        let closings = zip(state.members, hears).map { $0.duck.close(entry: entry, refusePending: deciding && $1) }
        entries[entry] = nil
        let answers = zip(closings, hears).map { closing, hears in
            AmbientPrivacyChildAnswer(answer: closing.answer ?? .timeout, listening: hears, claimed: closing.claimed,
                                      refusedAtBound: closing.refused)
        }
        let claimed = state.carried || answers.contains(where: \.claimed)
        let took = zip(state.members, closings).filter(\.1.claimed).map(\.0.child)
        let refused = zip(state.members, closings).filter(\.1.refused).map(\.0.child)
        guard state.withdrawn || deciding else {
            if claimed { entries[newest]?.carried = true }
            let tokens = " superseded_by_newer" + (claimed ? " carried" : "")
            return .decided(.init(clip: nil, tokens: tokens, claimed: took))
        }
        let answer = AmbientRightyoRouter.privacyVerdict(answers, withdrawn: state.withdrawn, carried: state.carried)
        let (clip, tokens) = AmbientRightyoRouter.announcement(answer, claimed: claimed, wasOn: state.wasOn)
        if let clip { said = clip == AmbientStopConfirmation.privacyOn ? .on : .unavailable }
        return .decided(.init(clip: clip, tokens: tokens, claimed: took, refused: refused))
    }
}

/// Every privacy entry is announced within a bound (#735 S-8 HS-C, Mick: "We should not change state unless we're
/// announcing it."): exactly one of `confirm-privacy-on/` or `confirm-privacy-unavailable/` plays for it, on the
/// connection's one clip chain (round 3), or a logged silence: withdrawn by an off ("Recording again." follows), or
/// superseded by a newer entry, which announces the outcome (round 4).
extension AmbientRightyoRouter {
    /// The margin past a child's start and ack deadlines (round 3): each child's bound is start + ack + this (16 s by
    /// default) from when the entry opened on it (round 4: its registration, for a child a reload started meanwhile),
    /// so it only ends a wait none of that child's own deadlines ended.
    static let privacyConfirmMargin: TimeInterval = 1

    /// The entry's clip and log tokens, given its answer, whether it took over a refusal (claimed or carried), and
    /// whether privacy was already on: `confirm-privacy-on/` when kept (`superseded_by_keep` for a refusal it took
    /// over: a listening child still keeps privacy, so nothing changed); nothing when withdrawn (`superseded_by_off`
    /// for a refusal: "Recording again." is the last word); else `confirm-privacy-unavailable/`.
    static func announcement(_ answer: AmbientPrivacyAnswer, claimed: Bool, wasOn: Bool) -> (String?, String) {
        switch answer {
        case .kept:
            return (AmbientStopConfirmation.privacyOn,
                    (wasOn ? " still_on" : "") + (claimed ? " superseded_by_keep" : ""))
        case .withdrawn:
            return (nil, claimed ? " withdrawn claimed superseded_by_off" : " withdrawn")
        default:
            return (AmbientStopConfirmation.privacyUnavailable, " \(answer.token)")
        }
    }

    /// The entry's answer from its children's at the close (round 4, the state rule): withdrawn by an off; `timeout`
    /// when a bound refused one; then a refusal of a listening child; then the listening children, those that ended
    /// dropping out: all kept is `kept` (a refusal of a child that no longer listens changes nothing then); none left
    /// is a refusal it took over (its own reason, or `refused` when carried) or `ended`; else the first not kept.
    static func privacyVerdict(_ answers: [AmbientPrivacyChildAnswer], withdrawn: Bool,
                               carried: Bool = false) -> AmbientPrivacyAnswer {
        if withdrawn { return .withdrawn }
        if answers.contains(where: \.refusedAtBound) { return .timeout }
        let refusal = answers.first { child in
            guard case .refused = child.answer else { return false }
            return child.listening
        }
        if let refusal { return refusal.answer }
        let present = answers.filter { $0.listening && $0.answer != .ended }.map(\.answer)
        if let other = present.first(where: { $0 != .kept }) { return other }
        if !present.isEmpty { return .kept }
        if let claimed = answers.first(where: { $0.claimed }) { return claimed.answer }
        return carried ? .refused(nil) : .ended
    }
}
#endif
