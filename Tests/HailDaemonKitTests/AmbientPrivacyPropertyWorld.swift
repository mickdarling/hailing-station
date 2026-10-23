#if os(macOS)
import Foundation
@testable import HailDaemonKit

/// The router's side of the simulation (#735 S-8 HS-C round 3): entries, offs, reloads, a refused start, and each
/// entry's close, verdict and place on the connection's one clip chain, as separate steps.
extension PrivacySimWorld {
    /// `switchDuck(true)`: an entry opens when a child took it or privacy was already on; queued on the chain.
    func enter() {
        let wasOn = on
        let reported = live.filter { report($0, true) }.count
        guard reported > 0 || wasOn else {
            live.forEach { _ = report($0, false) }
            return
        }
        on = true
        let entry = entries.count + 1
        live.forEach { $0.duck.open(entry: entry) }
        entries[entry] = PrivacySimEntry(wasOn: wasOn, openedAt: time, opened: live)
        chain.append(.entry(entry))
    }

    /// `switchDuck(false)`: withdraws every entry still open; "Recording again." is queued.
    func exit() {
        guard on else { return }
        live.forEach { _ = report($0, false) }
        on = false
        withdrawn.formUnion(openEntries)
        chain.append(.off)
    }

    /// A new stream's child, or a reload's (`replacing`): it starts private while privacy is on, and every entry still
    /// open is opened on it too (`register`).
    func spawn(_ kind: PrivacySimChild.Kind, writeFails: Bool, replacing old: PrivacySimChild?) {
        if let old {
            (old.replaced, old.listening) = (true, false)
            old.duck.markReplaced()
        }
        let child = PrivacySimChild(index: children.count, kind: kind, startsPrivate: on, writeFails: writeFails)
        children.append(child)
        arm(.start, child, after: Self.startDeadline)
        _ = report(child, on)
        for entry in openEntries {
            child.duck.open(entry: entry)
            entries[entry]?.opened.append(child)
        }
    }

    /// The router's `refuse()`: a start refused while private, said by the latest open entry, else on the chain.
    func refuseStart() {
        guard on else { return }
        if let entry = openEntries.last { return _ = startRefused.insert(entry) }
        chain.append(.own(-1))
    }

    /// The entry at the chain's head, if it is one.
    var head: Int? {
        guard case .entry(let entry)? = chain.first else { return nil }
        return entry
    }

    /// The close (`closePrivacyEntry`), only for the entry the chain is running: each child closed and read in one
    /// step; nil from the router while it must still wait. Round two's ordering reads the answers at an earlier step.
    func close() {
        guard let entry = head, var state = entries[entry], !state.closed else { return }
        let timedOut = time >= state.openedAt + Self.bound
        let children = state.opened.map { AmbientPrivacyEntryChild(duck: $0.duck, listening: $0.listening) }
        if ordering == .roundTwo, state.early == nil {
            guard withdrawn.contains(entry) || timedOut || !children.contains(where: {
                $0.listening && $0.duck.settled == nil
            }) else { return }
            entries[entry]?.early = children.map { child in
                AmbientPrivacyChildAnswer(answer: child.duck.settled ?? .timeout, listening: child.listening,
                                          retired: child.duck.retired)
            }
            return
        }
        guard let closed = AmbientRightyoRouter.closeEntry(entry, children: children,
                                                           withdrawn: withdrawn.contains(entry), timedOut: timedOut)
        else { return }
        tick += 1
        state.closedTick = tick
        state.truthful = state.opened.allSatisfy { child in
            if case .refused? = child.duck.settled, !child.duck.retired { return false }
            return !child.listening || child.duck.settled == .kept
        }
        for (child, (answer, refused)) in zip(state.opened, closed) {
            if answer.claimed { child.claimed += 1 }
            guard refused else { continue }
            // A wait the entry began (a start at most S away, then an ack at most A) is ended by a deadline first.
            if child.deadlineAt <= state.openedAt + Self.startDeadline + Self.ackDeadline {
                failures.append("the bound cut short child \(child.index)'s wait before its deadline (entry \(entry))")
            }
            kill(child)
        }
        state.answers = closed.map(\.0)
        state.startRefused = startRefused.remove(entry) != nil
        if !live.filter(\.listening).allSatisfy({ child in state.opened.contains { $0 === child } }) {
            failures.append("entry \(entry) closed without a listening child")
        }
        entries[entry] = state
    }

    /// The verdict, any number of steps after the close: the router's own verdict and announcement.
    func verdict() {
        guard let entry = head, var state = entries[entry], let answers = state.answers, state.clip == nil else {
            return
        }
        let claimed = state.startRefused || answers.contains(where: \.claimed)
        // Round two decided from the answers read before the close, which knew nothing of its claims.
        let counted = state.early ?? answers
        let answer = AmbientRightyoRouter.privacyVerdict(counted, withdrawn: withdrawn.contains(entry),
                                                         startRefused: state.startRefused)
        let (clip, tokens) = AmbientRightyoRouter.announcement(answer, claimed: claimed, wasOn: state.wasOn)
        (state.clip, state.tokens) = (.some(clip), tokens)
        if clip == AmbientStopConfirmation.privacyOn, !state.truthful {
            failures.append("privacy on while a counted child was refused or unproven (entry \(entry)\(tokens))")
        }
        if clip == nil, !withdrawn.contains(entry) { failures.append("entry \(entry) silent as\(tokens)") }
        if tokens.contains("superseded_by_keep"), answers.contains(where: { $0.claimed && !$0.retired }) {
            failures.append("entry \(entry) absorbed a listening child's refusal")
        }
        entries[entry] = state
    }

    /// Plays the chain's head: an entry only once its verdict is in (its stop first, then its clip), or a refusal or
    /// an off.
    func play() {
        guard let item = chain.first else { return }
        switch item {
        case .entry(let entry):
            guard let decided = entries[entry]?.clip else { return }
            if let clip = decided {
                played += [.stop(entry), clip == AmbientStopConfirmation.privacyOn ? .on(entry) : .unavailable(entry)]
            } else {
                played.append(.withdrawn(entry))
            }
        case .own(let child): played.append(.own(child))
        case .off: played.append(.off)
        }
        chain.removeFirst()
    }

    /// The bound: every deadline fires, every handler runs, and every entry is closed, decided and played.
    func finish() {
        advance(by: 1_000)
        for _ in 0..<200 where !(chain.isEmpty && handlers.isEmpty) {
            while !handlers.isEmpty { runHandler(0) }
            close()
            close()
            verdict()
            play()
        }
        if !chain.isEmpty { failures.append("the chain never drained") }
    }
}
#endif
