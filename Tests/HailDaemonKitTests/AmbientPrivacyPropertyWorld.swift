#if os(macOS)
import Foundation
@testable import HailDaemonKit

/// The router's side of the simulation (#735 S-8 HS-C round 4): switches, registration, a refused start, and each
/// entry's close and place on the connection's one clip chain, through the router's own ledger.
extension PrivacySimWorld {
    /// `switchDuck(true)`: an entry opens when a child took it or privacy was already on; its clip is queued as decided.
    func enter() {
        let wasOn = on
        let reported = live.filter { report($0, true) }.count
        guard reported > 0 || wasOn else {
            live.forEach { _ = report($0, false) }
            return
        }
        on = true
        queue(.entry(ledger.open(on: live.map { ($0, $0.duck) }, wasOn: wasOn, at: time)))
    }

    /// `switchDuck(false)`: every open entry is withdrawn; "Recording again." is queued when a child took it, else the
    /// device notice alone tells it (`duckConfirmation`).
    func exit() {
        guard on else { return }
        let reported = live.filter { report($0, false) }.count
        on = false
        ledger.withdrawAll()
        let clip = AmbientRightyoRouter.duckConfirmation(.exit, reported: reported, on: false).0
        queue(clip == nil ? .offNotice : .off)
    }

    /// A switch's clip: on the chain in the same step, or (`splitEnqueue`) decided now and queued in a later step.
    func queue(_ item: PrivacySimItem) {
        if faults.contains(.splitEnqueue) { pending.append(item) } else { chain.append(item) }
    }

    /// a8de9f2's late enqueue: any switch decided but not yet queued is queued now, in any order.
    func flush(_ index: Int) {
        guard pending.indices.contains(index) else { return }
        chain.append(pending.remove(at: index))
    }

    /// A new stream's child (the gate ends the older stream first, so it drains), or a reload's (`replacing`): it
    /// starts private while privacy is on, and registers with the ledger (`register`), which may open a recovery entry.
    func spawn(_ kind: PrivacySimChild.Kind, writeFails: Bool, replacing old: PrivacySimChild?) {
        if let old {
            (old.replaced, old.listening) = (true, false)
        } else {
            hearing.forEach { ($0.drained, $0.listening) = (true, false) }
        }
        let child = PrivacySimChild(index: children.count, kind: kind, startsPrivate: on, writeFails: writeFails)
        children.append(child)
        arm(.start, child, after: Self.startDeadline)
        _ = report(child, on)
        if let entry = ledger.register(child, duck: child.duck, at: time, on: on, all: live.map { ($0, $0.duck) }) {
            recoveries.insert(entry)
            chain.append(.entry(entry))
        }
    }

    /// The router's `refuse()`: a start refused while private, through the ledger's state rule.
    func refuseStart() {
        if ledger.refusal(of: nil, on: on, holders: hearing.map(\.duck)).0 { chain.append(.own(-1)) }
    }

    /// The entry at the chain's head, if it is one still open.
    var head: Int? {
        guard case .entry(let entry)? = chain.first, ledger.entries[entry] != nil else { return nil }
        return entry
    }

    /// When the running entry must next be closed: the earliest listening child's own bound (`entryBound`: the
    /// entry's), while it waits for a proof, and at the latest its cap (round 5; never under `uncapped`).
    var boundDue: Double? {
        guard let entry = head, let state = ledger.entries[entry], !state.withdrawn, ledger.last == entry else {
            return nil
        }
        let waiting = state.members.filter { $0.child.listening && $0.duck.settled == nil }
        if faults.contains(.entryBound) { return waiting.isEmpty ? nil : state.opened + Self.bound }
        let due = waiting.map { $0.opened + Self.bound }.min()
        return faults.contains(.uncapped) ? due : due.map { min($0, state.opened + Self.cap) }
    }

    /// The close (`closePrivacyEntry`), only for the entry the chain is running, with the listening set derived from
    /// the runs. Under `entryBound`, a8de9f2's bound first refuses every pending listening child from the entry's open.
    func close() {
        guard let entry = head, let state = ledger.entries[entry] else { return }
        if faults.contains(.entryBound), time >= state.opened + Self.bound, !state.withdrawn, ledger.last == entry {
            for member in state.members where member.child.listening && member.duck.settled == nil {
                let closing = member.duck.close(entry: entry, refusePending: true)
                if closing.claimed { member.child.claimed += 1 }
                if closing.refused { boundKill(member.child, entry: entry) }
            }
        }
        if !hearing.allSatisfy({ child in state.members.contains { $0.child === child } }) {
            failures.append("entry \(entry) is missing a listening child")
        }
        let cap = faults.contains(.uncapped) ? Double.infinity : nil
        guard case .decided(let decision) = ledger.close(entry, now: time, bound: Self.bound, cap: cap,
                                                         listening: \.listening) else {
            // (d) Round 5: every entry decides within its cap, however many children register meanwhile.
            if !state.withdrawn, ledger.last == entry, time >= state.opened + Self.cap, overCap.insert(entry).inserted {
                failures.append("entry \(entry) still waits at \(time), past its cap at \(state.opened + Self.cap)")
            }
            return
        }
        tick += 1
        decision.claimed.forEach { $0.claimed += 1 }
        decision.refused.forEach { boundKill($0, entry: entry) }
        if let recovery = decision.recovery {
            recoveries.insert(recovery)
            chain.append(.entry(recovery))
        }
        decided[entry] = PrivacySimDecision(clip: decision.clip, tokens: decision.tokens, tick: tick,
                                            members: state.members.map(\.child))
        judge(entry, decision, withdrawn: state.withdrawn)
    }

    /// (a) A child is killed by a bound only once its own deadline passed.
    func boundKill(_ child: PrivacySimChild, entry: Int) {
        if time < child.deadlineAt {
            failures.append("entry \(entry)'s bound killed child \(child.index) at \(time), before its own deadline "
                + "at \(child.deadlineAt)")
        }
        kill(child)
    }

    /// (c) Truthful, computed from the world, not the verdict: privacy on, a child listening, every one proven.
    func judge(_ entry: Int, _ decision: AmbientPrivacyDecision<PrivacySimChild>, withdrawn: Bool) {
        let truthful = on && !hearing.isEmpty && hearing.allSatisfy { $0.duck.settled == .kept }
        switch decision.clip {
        case AmbientStopConfirmation.privacyOn? where !truthful:
            failures.append("entry \(entry) said privacy on while a listening child was refused or unproven")
        case AmbientStopConfirmation.privacyUnavailable? where truthful:
            failures.append("entry \(entry) said unavailable while privacy was kept\(decision.tokens)")
        // Only a recovery entry may stay silent as already unavailable: an owner's request is always answered.
        case nil where decision.tokens.hasSuffix("already_unavailable")
            && (truthful || ledger.said != .unavailable || !recoveries.contains(entry)):
            failures.append("entry \(entry) silent as already unavailable\(decision.tokens)")
        case nil where !withdrawn && !decision.tokens.contains("superseded_by_newer")
            && !decision.tokens.hasSuffix("already_unavailable"):
            failures.append("entry \(entry) silent as\(decision.tokens)")
        case nil where decision.tokens.contains("superseded_by_newer") && ledger.last <= entry:
            failures.append("entry \(entry) superseded by no newer entry")
        default: break
        }
    }

    /// Plays the chain's head: an entry only once decided (its stop first, then its clip), or a refusal or an off.
    func play() {
        guard let item = chain.first else { return }
        switch item {
        case .entry(let entry):
            guard let decision = decided[entry] else { return }
            if let clip = decision.clip {
                played += [.stop(entry), clip == AmbientStopConfirmation.privacyOn ? .on(entry) : .unavailable(entry)]
            } else {
                played.append(.silent(entry))
            }
        case .own(let child): played.append(.own(child))
        case .off: played.append(.off)
        case .offNotice: played.append(.offNotice)
        }
        chain.removeFirst()
    }

    /// The bound: every deadline fires, every handler runs, every switch is queued, and every entry is closed and played.
    func finish() {
        advance(by: 1_000)
        for _ in 0..<400 where !(chain.isEmpty && handlers.isEmpty && pending.isEmpty) {
            while !pending.isEmpty { flush(0) }
            while !handlers.isEmpty { runHandler(0) }
            close()
            play()
        }
        if !chain.isEmpty { failures.append("the chain never drained") }
    }
}
#endif
