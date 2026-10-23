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

/// One simulated child of a connection (#735 S-8 HS-C): the real `AmbientDuckControl`, with the router's view of it.
final class PrivacySimChild {
    enum Kind: CaseIterable { case v3, v2 }
    let duck: AmbientDuckControl
    let index: Int, kind: Kind, startsPrivate: Bool, writeFails: Bool
    /// `listening`: its run is registered and not retired; `gone`: its run was removed (the router no longer has it).
    var started = false, listening = true, replaced = false, drained = false, gone = false
    /// Refused and killed (its `unavailable` handler is queued), and the step it was refused at.
    var killed = false, refusedTick = 0
    var writes = 0, acks = 0, said = 0, claimed = 0
    /// When the deadline that would end its current wait for proof falls (start, fresh start or latest ack).
    var deadlineAt = 0.0

    init(index: Int, kind: Kind, startsPrivate: Bool, writeFails: Bool) {
        (self.index, self.kind, self.startsPrivate, self.writeFails) = (index, kind, startsPrivate, writeFails)
        duck = AmbientDuckControl(startPrivate: startsPrivate)
    }

    var startedLine: Data {
        let duck = kind == .v3 ? #""duck": {"version": 3, "private": true}, "# : ""
        let line = #"{"type": "session", "#
        return Data((line + duck + #""phase": "started"}"#).utf8)
    }
}

/// A child's deadline, as the pipeline arms it: its start deadline, a fresh one (round 2), or an on-write's ack.
struct PrivacySimTimer {
    enum Kind: Equatable { case start, freshStart, ack(Int) }
    let at: Double, child: Int, kind: Kind
}

/// The connection's one clip chain (round 3): an entry's announcement, a child's own refusal (or the router's refused
/// start, child -1), and an off's "Recording again.".
enum PrivacySimItem { case entry(Int), own(Int), off }

/// What the chain played, in order: an entry's stop then its clip, an entry's logged silence, a refusal, an off.
enum PrivacySimClip: Equatable { case stop(Int), on(Int), unavailable(Int), withdrawn(Int), own(Int), off }

/// One simulated privacy entry.
struct PrivacySimEntry {
    let wasOn: Bool, openedAt: Double
    var opened: [PrivacySimChild] = []
    /// Round two's ordering only: the answers read at the verdict, before the close.
    var early: [AmbientPrivacyChildAnswer]?
    var answers: [AmbientPrivacyChildAnswer]?
    var closedTick: Int?, startRefused = false, truthful = false
    var clip: String??
    var tokens = ""
    var closed: Bool { closedTick != nil }
}

/// The connection: the router's entry protocol over real duck controls, on a simulated clock, driven one step at a
/// time. The close and the verdict are the router's own `closeEntry`, `privacyVerdict` and `announcement`; the bound is
/// derived as the router derives it.
final class PrivacySimWorld {
    enum Ordering { case closeFirst, roundTwo }
    static let (startDeadline, ackDeadline) = (RightyoAmbientPipeline.defaultStartDeadline,
                                               RightyoAmbientPipeline.ackDeadline)
    static let bound = startDeadline + ackDeadline + AmbientRightyoRouter.privacyConfirmMargin
    let ordering: Ordering
    var time = 0.0, tick = 0, on = false
    var children: [PrivacySimChild] = [], timers: [PrivacySimTimer] = []
    var entries: [Int: PrivacySimEntry] = [:], withdrawn: Set<Int> = [], startRefused: Set<Int> = []
    var chain: [PrivacySimItem] = [], played: [PrivacySimClip] = [], handlers: [PrivacySimChild] = []
    var failures: [String] = []

    init(ordering: Ordering = .closeFirst) { self.ordering = ordering }

    var live: [PrivacySimChild] { children.filter { !$0.gone } }
    var openEntries: [Int] { entries.filter { !$0.value.closed }.keys.sorted() }

    func arm(_ kind: PrivacySimTimer.Kind, _ child: PrivacySimChild, after seconds: Double) {
        if kind == .freshStart { timers.removeAll { $0.child == child.index && $0.kind == .freshStart } }
        timers.append(PrivacySimTimer(at: time + seconds, child: child.index, kind: kind))
        child.deadlineAt = time + seconds
    }

    func report(_ child: PrivacySimChild, _ on: Bool) -> Bool {
        child.duck.report(on, write: { [writeFails = child.writeFails] _ in !writeFails }, written: { write in
            child.writes = write
            self.arm(.ack(write), child, after: Self.ackDeadline)
        }, restart: { self.arm(.freshStart, child, after: Self.startDeadline) })
    }

    func start(_ child: PrivacySimChild) {
        guard !child.started, !child.gone, !child.killed else { return }
        child.started = true
        let written: (Int) -> Void = { write in
            child.writes = write
            self.arm(.ack(write), child, after: Self.ackDeadline)
        }
        guard child.duck.observe(started: child.startedLine, write: { [writeFails = child.writeFails] _ in
            !writeFails
        }, written: written) == .refused else { return }
        guard child.startsPrivate || on else { return child.duck.release() }
        child.duck.refuseStart(as: child.startsPrivate ? .unconfirmedStart : .unsupportedChild)
        kill(child)
    }

    /// An ack line; an excess one ends the run, refusing the child first while privacy is wished for.
    func ack(_ child: PrivacySimChild) {
        guard child.started, !child.gone, !child.killed else { return }
        guard child.duck.acknowledge() == .excess else { return child.acks += 1 }
        if child.duck.refuseIfWished() { kill(child) }
        end(child)
    }

    /// A healthy child's ack: only for an on-write it still owes one (`ack` alone may be excess).
    func ackOwed(_ child: PrivacySimChild) {
        guard child.acks < child.writes else { return }
        ack(child)
    }

    /// When the running entry's bound passes, if it is still open (its close is then due at once).
    var boundDue: Double? {
        guard case .entry(let entry)? = chain.first, let state = entries[entry], !state.closed else { return nil }
        return state.openedAt + Self.bound
    }

    /// Advances the clock, firing each deadline due on the way, in time order, as the pipeline's tasks do; the running
    /// entry's bound among them (its close, with the bound passed).
    func advance(by seconds: Double) {
        let until = time + seconds
        while true {
            let next = timers.filter({ $0.at <= until }).min(by: { $0.at < $1.at })
            if let bound = boundDue, bound <= until, bound < next?.at ?? .infinity {
                time = max(time, bound)
                close()
                continue
            }
            guard let next else { break }
            timers.removeAll { $0.at == next.at && $0.child == next.child && $0.kind == next.kind }
            time = max(time, next.at)
            let child = children[next.child]
            guard !child.gone else { continue }
            switch next.kind {
            case .start, .freshStart: if child.duck.expire() { kill(child) }
            case .ack(let write): if child.duck.expireAck(write) { kill(child) }
            }
        }
        time = until
    }

    func kill(_ child: PrivacySimChild) {
        tick += 1
        (child.killed, child.refusedTick) = (true, tick)
        handlers.append(child)
    }

    /// The run ends (a crash, or the reap after a kill): the router removes it, and its deadlines are cancelled.
    func end(_ child: PrivacySimChild) {
        child.duck.end()
        (child.gone, child.listening) = (true, false)
        timers.removeAll { $0.child == child.index }
    }

    /// The router's handling of a refused child's `unavailable` (`voiceDuck`): silent for a replaced child; said by
    /// the child itself on the chain unless an entry says it. Its run then ends (the pipeline throws).
    func runHandler(_ index: Int) {
        guard handlers.indices.contains(index) else { return }
        let child = handlers.remove(at: index)
        defer { if !child.gone { end(child) } }
        guard !child.duck.replaced, child.duck.takeAnnouncement() else { return }
        child.said += 1
        tick += 1
        chain.append(.own(child.index))
    }
}
#endif
