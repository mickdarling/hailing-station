#if os(macOS)
import Foundation
@testable import HailDaemonKit

/// The connection (#735 S-8 HS-C round 4): real duck controls, and the router's own `AmbientPrivacyLedger` (its
/// opening, registration, off, refusal rule and close), on a simulated clock, driven one step at a time. The decision
/// and the queueing of a switch's clip are separate steps only under the `splitEnqueue` fault, as a8de9f2 had them.
final class PrivacySimWorld {
    static let (startDeadline, ackDeadline) = (RightyoAmbientPipeline.defaultStartDeadline,
                                               RightyoAmbientPipeline.ackDeadline)
    static let bound = startDeadline + ackDeadline + AmbientRightyoRouter.privacyConfirmMargin
    let faults: PrivacySimFaults
    var time = 0.0, tick = 0, on = false
    var children: [PrivacySimChild] = [], timers: [PrivacySimTimer] = []
    var ledger = AmbientPrivacyLedger<PrivacySimChild>()
    var decided: [Int: PrivacySimDecision] = [:]
    /// The chain, a switch's clips decided but not yet queued (`splitEnqueue` only), what played, and the refused
    /// children whose `unavailable` handler has not yet run (a deadline task: kill, then the handler).
    var chain: [PrivacySimItem] = [], pending: [PrivacySimItem] = [], played: [PrivacySimClip] = []
    var handlers: [PrivacySimChild] = [], failures: [String] = []
    /// The recovery entries a registration opened (round 4).
    var recoveries: Set<Int> = []

    init(faults: PrivacySimFaults = []) { self.faults = faults }

    var live: [PrivacySimChild] { children.filter { !$0.gone } }
    var hearing: [PrivacySimChild] { children.filter(\.listening) }

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

    /// The child's `started`: one that cannot keep the privacy wished for is refused and killed, and its handler runs
    /// before its run ends (the pipeline says it, then throws).
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
        child.misbehaved = true
        kill(child)
        runHandler(handlers.count - 1)
    }

    /// An ack line; an excess one ends the run, refusing the child first (and saying it) while privacy is wished for.
    func ack(_ child: PrivacySimChild) {
        guard child.started, !child.gone, !child.killed else { return }
        guard child.duck.acknowledge() == .excess else { return child.acks += 1 }
        if child.duck.refuseIfWished() {
            child.misbehaved = true
            kill(child)
            runHandler(handlers.count - 1)
        }
        end(child)
    }

    /// A healthy child's ack: only for an on-write it still owes one (`ack` alone may be excess).
    func ackOwed(_ child: PrivacySimChild) {
        guard child.acks < child.writes else { return }
        ack(child)
    }

    /// Advances the clock, firing each deadline due on the way, in time order, as the pipeline's tasks do; the running
    /// entry's bound among them (its close is then due).
    func advance(by seconds: Double) {
        let until = time + seconds
        while true {
            let next = timers.filter({ $0.at <= until }).min(by: { $0.at < $1.at })
            if let bound = boundDue, bound <= until, bound < next?.at ?? .infinity {
                time = max(time, bound)
                close()
                if boundDue == bound {
                    failures.append("the bound at \(bound) made no progress")
                    break
                }
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

    /// The run ends (a crash, or the reap after a kill): the router removes it, its pipeline is freed, and its
    /// deadlines are cancelled; a deadline task already past its check still holds the duck and runs its handler.
    func end(_ child: PrivacySimChild) {
        child.duck.end()
        (child.gone, child.listening) = (true, false)
        timers.removeAll { $0.child == child.index }
    }

    /// The router's handling of a refused child's `unavailable` (`announceRefusal`): the ledger's state rule over the
    /// strongly held duck, queued at once. Under `weakGuards`, a8de9f2's: a freed pipeline reads every guard as nil,
    /// so it speaks. Its run then ends.
    func runHandler(_ index: Int) {
        guard handlers.indices.contains(index) else { return }
        let child = handlers.remove(at: index)
        defer { if !child.gone { end(child) } }
        if faults.contains(.weakGuards), child.gone {
            child.said += 1
            chain.append(.own(child.index))
            return
        }
        let (said, token) = ledger.refusal(of: child.duck, on: on, holders: hearing.map(\.duck))
        if said {
            child.said += 1
            chain.append(.own(child.index))
        } else if token?.hasSuffix("carried") == true {
            child.carried += 1
        } else if token?.contains("superseded") == true {
            child.silenced += 1
        }
    }
}
#endif
