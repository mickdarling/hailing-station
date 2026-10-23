#if os(macOS)
import Foundation
@testable import HailDaemonKit

/// A deterministic generator per seed (SplitMix64), so a failing seed replays exactly.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// One simulated child of a connection (#735 S-8 HS-C round 2): the real `AmbientDuckControl`, with the router's view.
final class PrivacySimChild {
    enum Kind: CaseIterable { case v3, v2 }
    let duck: AmbientDuckControl
    let kind: Kind, startsPrivate: Bool, writeFails: Bool
    var started = false, listening = true, replaced = false, drained = false, gone = false
    /// Refused and killed, so its `unavailable` is due once. A child whose on-write failed also settles `refused`, but
    /// is never killed: each entry it answers for says `unavailable` through the verdict instead (seed 173).
    var killed = false
    var writes = 0, said = 0, claimed = 0
    /// The open entry its refusal was attributed to, as the duck attributes it (the latest still open).
    var attributed: Int?

    init(kind: Kind, startsPrivate: Bool, writeFails: Bool) {
        (self.kind, self.startsPrivate, self.writeFails) = (kind, startsPrivate, writeFails)
        duck = AmbientDuckControl(startPrivate: startsPrivate)
    }

    var startedLine: Data {
        let duck = kind == .v3 ? #""duck": {"version": 3, "private": true}, "# : ""
        let line = #"{"type": "session", "#
        return Data((line + duck + #""phase": "started"}"#).utf8)
    }

    func report(_ on: Bool) -> Bool {
        duck.report(on, write: { [writeFails] _ in !writeFails }, written: { [self] write in writes = write })
    }
}

/// One simulated privacy entry: its clip (`on` or `unavailable`), and whether an off came while it was open.
struct PrivacySimEntry {
    let wasOn: Bool
    var open = true, offWhileOpen = false
    /// Refusal clips said by the child itself while attributed to this entry (must stay 0 when the entry spoke).
    var refusalClips = 0
    var clip: String?, answer: AmbientPrivacyAnswer?
}

/// The connection: the router's entry protocol over real duck controls, driven one step at a time. The answer and the
/// announcement come from the router's own `privacyVerdict` and `announcement`.
final class PrivacySimWorld {
    var on = false, children: [PrivacySimChild] = [], entries: [Int: PrivacySimEntry] = [:]
    var opened: [Int: [PrivacySimChild]] = [:], handlers: [PrivacySimChild] = [], failures: [String] = []
    var live: [PrivacySimChild] { children.filter { !$0.gone } }

    func enter() {
        let wasOn = on
        let reported = live.filter { $0.report(true) }.count
        guard reported > 0 || wasOn else {
            live.forEach { _ = $0.report(false) }
            return
        }
        on = true
        let entry = entries.count + 1
        live.forEach { $0.duck.open(entry: entry) }
        (opened[entry], entries[entry]) = (live, PrivacySimEntry(wasOn: wasOn))
    }

    func exit() {
        guard on else { return }
        live.forEach { _ = $0.report(false) }
        on = false
        for (entry, state) in entries where state.open { entries[entry]?.offWhileOpen = true }
    }

    func spawn(_ kind: PrivacySimChild.Kind, writeFails: Bool, replacing old: PrivacySimChild?) {
        if let old { (old.replaced, old.listening) = (true, false) }
        let child = PrivacySimChild(kind: kind, startsPrivate: on, writeFails: writeFails)
        _ = child.report(on)
        for (entry, state) in entries where state.open {
            child.duck.open(entry: entry)
            opened[entry]?.append(child)
        }
        children.append(child)
    }

    func start(_ child: PrivacySimChild) {
        guard !child.started, !child.gone else { return }
        child.started = true
        let write: (Bool) -> Bool = { [writeFails = child.writeFails] _ in !writeFails }
        guard child.duck.observe(started: child.startedLine, write: write,
                                 written: { [child] in child.writes = $0 }) == .refused else { return }
        guard child.startsPrivate || on else { return child.duck.release() }
        child.duck.refuseStart(as: child.startsPrivate ? .unconfirmedStart : .unsupportedChild)
        kill(child)
    }

    func ack(_ child: PrivacySimChild) {
        guard child.started, !child.gone, child.duck.acknowledge() == .excess else { return }
        if child.duck.refuseIfWished() { return kill(child) }
        end(child)
    }

    func ackDeadline(_ child: PrivacySimChild) {
        if child.writes > 0, child.duck.expireAck(child.writes) { kill(child) }
    }

    func startDeadline(_ child: PrivacySimChild) { if child.duck.expire() { kill(child) } }

    /// Killed: its `unavailable` is handed to the router later (`runHandler`), its run ends.
    func kill(_ child: PrivacySimChild) {
        child.killed = true
        child.attributed = opened.filter { $0.value.contains { $0 === child } }.keys.max()
        handlers.append(child)
        end(child)
    }

    func end(_ child: PrivacySimChild) {
        child.duck.end()
        (child.gone, child.listening) = (true, false)
    }

    /// The router's handling of a refused child's `unavailable` (`voiceDuck`): silent for a replaced child, held back
    /// while its entry is open.
    func runHandler() {
        guard !handlers.isEmpty else { return }
        let child = handlers.removeFirst()
        guard !child.replaced, child.duck.takeAnnouncement() else { return }
        child.said += 1
        if let entry = child.attributed { entries[entry]?.refusalClips += 1 }
    }

    /// Announces `entry` once every child still listening answered, or at the bound (`timeout`).
    func resolve(_ entry: Int, timeout: Bool) {
        guard entries[entry]?.open == true else { return }
        let listening = children.filter(\.listening)
        let bound = timeout && listening.contains { $0.duck.settled == nil }
        if bound {
            for child in listening where child.duck.settled == nil && child.duck.refuseUnproven() { kill(child) }
        } else if listening.contains(where: { $0.duck.settled == nil }) { return }
        let answers = (opened[entry] ?? []).filter { !$0.listening && !$0.drained } + listening
        let settled = answers.compactMap { child in
            child.duck.settled.map {
                AmbientPrivacyChildAnswer(answer: $0, listening: child.listening, replaced: child.replaced)
            }
        }
        let answer = bound ? .timeout : AmbientRightyoRouter.privacyVerdict(settled, on: on)
        let claimed = (opened.removeValue(forKey: entry) ?? []).filter { $0.duck.close(entry: entry) }
        claimed.forEach { $0.claimed += 1 }
        let state = entries[entry] ?? PrivacySimEntry(wasOn: false)
        let (clip, tokens) = AmbientRightyoRouter.announcement(answer, claimed: !claimed.isEmpty, on: on,
                                                               wasOn: state.wasOn)
        checkSilences(entry, clip: clip, tokens: tokens, claimed: claimed)
        if clip == AmbientStopConfirmation.privacyOn, listening.contains(where: { !$0.duck.active
            || $0.duck.settled != .kept }) {
            failures.append("privacy on while a listening child had not proved it (entry \(entry))")
        }
        entries[entry]?.open = false
        entries[entry]?.clip = clip
        entries[entry]?.answer = answer
    }

    /// Each silence is logged (#735 S-8 HS-C round 2): no clip only as `withdrawn`, and a refusal absorbed by a kept
    /// entry (`superseded_by_keep`) only a draining or replaced child's.
    func checkSilences(_ entry: Int, clip: String?, tokens: String, claimed: [PrivacySimChild]) {
        if clip == nil, !tokens.hasPrefix(" withdrawn") { failures.append("entry \(entry) silent as\(tokens)") }
        guard tokens.contains("superseded_by_keep") else { return }
        if claimed.contains(where: { !$0.drained && !$0.replaced }) {
            failures.append("entry \(entry) absorbed a listening child's refusal")
        }
    }
}
#endif
