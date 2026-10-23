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
/// over, those their bound refused (to be killed), and (round 5) the recovery entry a cap opened, to be queued.
struct AmbientPrivacyDecision<Child: AnyObject> {
    let clip: String?
    let tokens: String
    var claimed: [Child] = [], refused: [Child] = []
    var recovery: Int?
}

/// Still to wait (until the earliest listening child's own bound, or the entry's cap), or decided.
enum AmbientPrivacyClose<Child: AnyObject> {
    case wait(until: Double)
    case decided(AmbientPrivacyDecision<Child>)
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
        /// An off withdrew it; a refusal another place would have said is carried to it; opened by no owner's command
        /// but after "unavailable" (round 5: it never repeats "unavailable").
        var withdrawn = false, carried = false, recovery = false
    }
    private(set) var entries: [Int: Entry] = [:]
    private(set) var last = 0
    /// The last clip decided for this connection's privacy state, nil before any.
    private(set) var said: AmbientPrivacySaid?

    /// Opens the next entry on `children` (every child of the connection) at `now`.
    mutating func open(on children: [(Child, AmbientDuckControl)], wasOn: Bool, at now: Double) -> Int {
        open(children.map { Member(child: $0.0, duck: $0.1, opened: now) }, wasOn: wasOn, at: now, recovery: false)
    }

    private mutating func open(_ members: [Member], wasOn: Bool, at now: Double, recovery: Bool) -> Int {
        last += 1
        members.forEach { $0.duck.open(entry: last) }
        entries[last] = Entry(opened: now, wasOn: wasOn, members: members, recovery: recovery)
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
        return open(all.map { Member(child: $0.0, duck: $0.1, opened: now) }, wasOn: true, at: now, recovery: true)
    }

    /// Whether a status may say privacy is on, given that it is armed (#735 S-8 HS-C, 6362119223): only once it was
    /// announced. Fails closed: only "Privacy on" as the last word, with no entry still unproven, is private to the
    /// owner; nothing announced yet, "unavailable" or an off is not. So a status asked before a re-entry or a refusal
    /// that opens or decides first is silent; their own clip follows.
    var heardOn: Bool { entries.values.allSatisfy(\.withdrawn) && said == .on }

    /// An off: every open entry is withdrawn, and "Recording again." is the last word.
    mutating func withdrawAll() {
        for key in entries.keys { entries[key]?.withdrawn = true }
        said = .off
    }

    /// The state rule for a refusal (`duck`, or nil for a start refused while private): whether `unavailable` is said
    /// now, else the log token. Said only when it changed the owner's state: never twice, never after an off, never
    /// while an open entry (the newest announces it, carried) or a listening child (`holders`) still keeps privacy,
    /// and never while "unavailable" is already the last word (round 5, `already_unavailable`: refused starts in a row).
    mutating func refusal(of duck: AmbientDuckControl?, on: Bool, holders: [AmbientDuckControl]) -> (Bool, String?) {
        if let duck, !duck.takeAnnouncement() { return (false, "unavailable=said_by_entry") }
        guard on else { return (false, duck == nil ? nil : "unavailable=superseded_by_off") }
        if let newest = entries.filter({ !$0.value.withdrawn }).keys.max() {
            entries[newest]?.carried = true
            return (false, "unavailable=said_by_entry carried")
        }
        if holders.contains(where: \.holdsPrivacy) { return (false, "unavailable=superseded_by_keep") }
        if said == .unavailable { return (false, "unavailable=already_unavailable") }
        said = .unavailable
        return (true, nil)
    }

    /// Closes `entry` at `now`, or says how long to wait: while a listening child's proof is still to come within its
    /// own bound (its open + `bound`), unless an off withdrew the entry or a newer one is open. Each child is closed
    /// and read in one step under its lock; one past its own bound is refused there (the ack or the bound, whichever
    /// came first). An older entry closing under a newer one says nothing (`superseded_by_newer`) and carries any
    /// refusal it claimed to the newest, which announces the outcome. Round 5: every entry decides by its cap, `cap`
    /// past its opening (nil: 2 × `bound`), however many children register meanwhile. At the cap it says "unavailable"
    /// (`timeout cap`) without refusing a child whose own bound has not passed; those listening go on in a recovery
    /// entry, which says "privacy on" once they prove it. A recovery entry never repeats "unavailable".
    mutating func close(_ entry: Int, now: Double, bound: Double, cap: Double? = nil,
                        listening: (Child) -> Bool) -> AmbientPrivacyClose<Child> {
        guard let state = entries[entry] else { return .decided(.init(clip: nil, tokens: " withdrawn")) }
        let newest = entries.keys.max() ?? entry
        let deciding = !state.withdrawn && newest == entry
        let hears = state.members.map { listening($0.child) }
        let late = zip(state.members, hears).map { member, hears in
            hears && member.duck.settled == nil && now < member.opened + bound
        }
        let capAt = state.opened + (cap ?? 2 * bound)
        if deciding, now < capAt, let until = zip(state.members, late).filter(\.1).map({ $0.0.opened + bound }).min() {
            return .wait(until: min(until, capAt))
        }
        let closings = zip(state.members, zip(hears, late)).map { member, flags in
            member.duck.close(entry: entry, refusePending: deciding && flags.0 && !flags.1)
        }
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
        let capped = deciding && late.contains(true)
        var decision = decide(state, answers, claimed: claimed, capped: capped)
        (decision.claimed, decision.refused) = (took, refused)
        if capped {
            let going = zip(state.members, hears).filter(\.1).map(\.0)
            decision.recovery = open(going, wasOn: true, at: now, recovery: true)
        }
        return .decided(decision)
    }

    /// The deciding entry's clip and tokens (`timeout cap` at its cap), and the last word it leaves: a recovery entry
    /// whose "unavailable" would repeat the last word says nothing (`already_unavailable`).
    private mutating func decide(_ state: Entry, _ answers: [AmbientPrivacyChildAnswer], claimed: Bool,
                                 capped: Bool) -> AmbientPrivacyDecision<Child> {
        let answer = capped ? .timeout
            : AmbientRightyoRouter.privacyVerdict(answers, withdrawn: state.withdrawn, carried: state.carried)
        var (clip, tokens) = AmbientRightyoRouter.announcement(answer, claimed: claimed, wasOn: state.wasOn)
        if capped { tokens += " cap" }
        if clip == AmbientStopConfirmation.privacyUnavailable, state.recovery, said == .unavailable {
            (clip, tokens) = (nil, tokens + " already_unavailable")
        }
        if let clip { said = clip == AmbientStopConfirmation.privacyOn ? .on : .unavailable }
        return .init(clip: clip, tokens: tokens)
    }
}

/// Every privacy entry is announced within a bound (#735 S-8 HS-C, Mick: "We should not change state unless we're
/// announcing it."): exactly one of `confirm-privacy-on/` or `confirm-privacy-unavailable/` plays for it, on the
/// connection's one clip chain (round 3), or a logged silence: withdrawn by an off ("Recording again." follows), or
/// superseded by a newer entry, which announces the outcome (round 4).
extension AmbientRightyoRouter {
    /// The margin past a child's start and ack deadlines (round 3): each child's bound is start + ack + this (18 s by
    /// default) from when the entry opened on it (round 4: its registration, for a child a reload started meanwhile),
    /// so it only ends a wait none of that child's own deadlines ended. Round 5: 3 s, so a late child's bound absorbs
    /// a `started` whose processing load delayed; an entry's cap is twice the bound (36 s).
    static let privacyConfirmMargin: TimeInterval = 3
}
#endif
