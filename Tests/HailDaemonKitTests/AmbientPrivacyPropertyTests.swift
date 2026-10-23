#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// A property test of the entry announcement (#735 S-8 HS-C round 4), over the real duck controls and the router's own
/// `AmbientPrivacyLedger` (opening, registration, off, the refusal rule and the close), on a simulated clock with
/// seeded random schedules: start timing (before the entry, after it, or never, with the fresh start deadline), ack
/// timing (prompt, late, never, excess), the real deadlines and per-child bounds racing acks, a failed on-write,
/// crashes, pipelines freed while a deadline task still runs, draining children and reloads at any point of an entry,
/// a refused start, a re-entry while on, and quick off/on. Over the ordered clip sequence: each entry plays exactly
/// one of "privacy on" or "unavailable" right after its stop, or a logged silence (withdrawn, or superseded by a
/// newer entry, which then speaks); "privacy on" only while every listening child is proven, and "unavailable" never
/// while privacy is kept (judged from the world, not the verdict); no child killed by a bound before its own deadline;
/// every refusal accounted for exactly once; and the last privacy clip matches the final state. Each failure names its
/// seed. a8de9f2's three faults, each alone, fail on the seeds recorded below.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyPropertyTests {
    static let seeds: [UInt64] = Array(1...300)
    static let steps = 150
    /// The first seed each a8de9f2 fault fails on (round 4, recorded from `roundThreesFaultsAreCaught`; round 5:
    /// `entryBound` moved from 23 to 48 with the 18 s bound).
    static let recorded: [(PrivacySimFaults, UInt64)] = [(.entryBound, 48), (.weakGuards, 2), (.splitEnqueue, 150)]

    @Test func everyEntryIsAnnouncedExactlyOnceInOrder() {
        for seed in Self.seeds {
            let failures = Self.run(seed: seed)
            #expect(failures.isEmpty, "seed \(seed): \(failures.joined(separator: "; "))")
        }
    }

    /// The model finds each of a8de9f2's faults on its own: the first failing seed is printed.
    @Test(arguments: [PrivacySimFaults.entryBound, .weakGuards, .splitEnqueue])
    func roundThreesFaultsAreCaught(_ fault: PrivacySimFaults) {
        let failing = (1...UInt64(2_000)).first { !Self.run(seed: $0, faults: fault).isEmpty }
        if let failing {
            print("a8de9f2 \(fault) fails at seed \(failing): \(Self.run(seed: failing, faults: fault))")
        }
        #expect(failing != nil)
    }

    /// The recorded seeds: each fails with its fault, and passes as fixed.
    @Test func theRecordedSeedsFailOnRoundThreeAndPassNow() {
        for (fault, seed) in Self.recorded {
            #expect(!Self.run(seed: seed, faults: fault).isEmpty, "\(fault) seed \(seed) no longer fails")
            #expect(Self.run(seed: seed).isEmpty, "seed \(seed): \(Self.run(seed: seed))")
        }
    }

    /// The per-child bound (finding 1): a reload late in an entry (at 14 s; the entry's own bound is at 18 s) registers
    /// a child that confirms its private start at 20 s, inside its own deadline: it is not killed, and the entry says
    /// "privacy on". Counted from the entry, as a8de9f2 did, it is killed at 18 s.
    @Test(arguments: [PrivacySimFaults(), .entryBound])
    func aReloadLateInAnEntryIsWaitedFor(_ faults: PrivacySimFaults) {
        let world = PrivacySimWorld(faults: faults)
        world.spawn(.v3, writeFails: false, replacing: nil)
        world.start(world.children[0])
        world.enter()
        world.ackOwed(world.children[0])
        world.advance(by: 14)
        world.spawn(.v3, writeFails: false, replacing: world.children[0])
        world.advance(by: 6)
        world.start(world.children[1])
        world.finish()
        let failures = world.failures + Self.check(world)
        if faults.isEmpty {
            #expect(failures.isEmpty, "\(failures)")
            #expect(world.played == [.stop(1), .on(1)] && !world.children[1].killed)
        } else {
            #expect(failures.contains { $0.contains("before its own deadline") }, "\(failures)")
        }
    }

    static func run(seed: UInt64, faults: PrivacySimFaults = []) -> [String] {
        var random = SeededGenerator(state: seed)
        let world = PrivacySimWorld(faults: faults)
        world.spawn(.v3, writeFails: false, replacing: nil)
        for _ in 0..<steps { step(world, &random) }
        world.finish()
        return world.failures + check(world)
    }

    static func step(_ world: PrivacySimWorld, _ random: inout SeededGenerator) {
        let action = Int.random(in: 0..<18, using: &random)
        let child = world.live.randomElement(using: &random)
        switch action {
        case ..<6: childStep(world, action, child, &random)
        case ..<12: worldStep(world, action, child, &random)
        default: chainStep(world, action, child, &random)
        }
    }

    /// The owner's entry, the child's own lines (start, acks: a healthy one or possibly excess).
    static func childStep(_ world: PrivacySimWorld, _ action: Int, _ child: PrivacySimChild?,
                          _ random: inout SeededGenerator) {
        switch (action, child) {
        case (0, _): world.enter()
        case (1, _): progress(world)
        case (2, _): if Int.random(in: 0..<3, using: &random) == 0 { world.exit() } else { world.play() }
        case (3, let child?): world.start(child)
        case (4, let child?) where Int.random(in: 0..<4, using: &random) == 0: world.ack(child)
        case (_, let child?): world.ackOwed(child)
        default: break
        }
    }

    /// Time (firing deadlines and bounds), a crash or reap, a drain, a spawn or reload, a deferred refusal handler.
    static func worldStep(_ world: PrivacySimWorld, _ action: Int, _ child: PrivacySimChild?,
                          _ random: inout SeededGenerator) {
        switch action {
        case 6:
            if Bool.random(using: &random), let child { return world.start(child) }
            world.advance(by: Double.random(in: 0.1...2, using: &random))
        case 7: world.advance(by: Double.random(in: 2...9, using: &random))
        case 8: child.map(world.end)
        case 9: child.map { ($0.listening, $0.drained) = (false, $0.listening || $0.drained) }
        case 10:
            let kind: PrivacySimChild.Kind = Int.random(in: 0..<4, using: &random) == 0 ? .v2 : .v3
            let old = Bool.random(using: &random) ? world.hearing.first : nil
            world.spawn(kind, writeFails: Int.random(in: 0..<12, using: &random) == 0, replacing: old)
        default: world.runHandler(Int.random(in: 0..<max(1, world.handlers.count), using: &random))
        }
    }

    /// A refused start or a late enqueue, the close and the chain as separate steps, and a quick off then on.
    static func chainStep(_ world: PrivacySimWorld, _ action: Int, _ child: PrivacySimChild?,
                          _ random: inout SeededGenerator) {
        switch action {
        case 12:
            if Int.random(in: 0..<3, using: &random) == 0 { return world.refuseStart() }
            world.flush(Int.random(in: 0..<max(1, world.pending.count), using: &random))
        case 13: world.close()
        case 14: world.flush(Int.random(in: 0..<max(1, world.pending.count), using: &random))
        case 15: world.play()
        case 16: progress(world)
        default:
            guard Int.random(in: 0..<3, using: &random) == 0 else { return child.map(world.ackOwed) ?? () }
            world.exit()
            world.enter()
        }
    }

    static func progress(_ world: PrivacySimWorld) {
        world.close()
        world.play()
    }
}
#endif
