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
    /// `listening`: its run is registered and neither retired nor gone, as the router derives it from its runs;
    /// `gone`: its run was removed, and (round 4) its pipeline freed, while a deadline task may still hold its duck.
    var started = false, listening = true, replaced = false, drained = false, gone = false
    /// Refused and killed, and the step it was refused at; `misbehaved`: refused for its own fault (a start that
    /// cannot keep privacy, an excess ack), never by a bound.
    var killed = false, refusedTick = 0, misbehaved = false
    /// How its refusal was accounted for: said by itself, claimed by an entry, carried to one, or silenced by the
    /// state rule (a listening child still keeps privacy, or an off came first).
    var writes = 0, acks = 0, said = 0, claimed = 0, carried = 0, silenced = 0
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

/// The connection's one clip chain (round 3): an entry's announcement, a child's own refusal (or a refused start,
/// child -1), and an off's "Recording again." (`offNotice`: an off no child took, told only by the device notice).
enum PrivacySimItem: Equatable { case entry(Int), own(Int), off, offNotice }

/// What the chain played, in order: an entry's stop then its clip, or its logged silence; a refusal; an off.
enum PrivacySimClip: Equatable { case stop(Int), on(Int), unavailable(Int), silent(Int), own(Int), off, offNotice }

/// How an entry closed: its clip and tokens, and the step.
struct PrivacySimDecision {
    let clip: String?, tokens: String, tick: Int
    let members: [PrivacySimChild]
}

/// The faults of a8de9f2 (round 3) that round 4 fixes, each switchable alone so its own failing seed is found:
/// `entryBound` (finding 1: the bound counted from the entry, refusing a child a reload registered late),
/// `weakGuards` (finding 2: a refusal said after its pipeline was freed reads every guard as nil, so it speaks), and
/// `splitEnqueue` (finding 3: a switch's clip queued after the router's lock was released).
struct PrivacySimFaults: OptionSet, Sendable, CustomStringConvertible {
    let rawValue: Int
    static let entryBound = Self(rawValue: 1)
    static let weakGuards = Self(rawValue: 2)
    static let splitEnqueue = Self(rawValue: 4)
    static let roundThree: Self = [.entryBound, .weakGuards, .splitEnqueue]

    var description: String {
        [(Self.entryBound, "entryBound"), (.weakGuards, "weakGuards"), (.splitEnqueue, "splitEnqueue")]
            .filter { contains($0.0) }.map(\.1).joined(separator: "+")
    }
}
#endif
