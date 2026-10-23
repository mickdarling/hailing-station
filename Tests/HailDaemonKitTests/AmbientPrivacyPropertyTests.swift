#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// A property test of the entry announcement (#735 S-8 HS-C round 3), over the real duck controls and the router's own
/// close, verdict and announcement, on a simulated clock with seeded random schedules: start timing (before the entry,
/// after it, or never, with the fresh start deadline), ack timing (prompt, late, never, excess), the real start and ack
/// deadlines and the derived bound racing acks, a failed on-write, crashes, draining children and reloads, a refused
/// start, a re-entry while on, and quick off/on. The close and the verdict are separate steps, with anything between
/// them, and every clip goes on one chain per connection. Over the ordered clip sequence: each entry plays exactly one
/// of "privacy on" or "unavailable", right after its playback stop (or nothing, logged, only when an off withdrew it);
/// never "privacy on" while a child it counted was refused or unproven at its close; a refusal said after an entry's
/// "privacy on" is one decided after its close; every refusal is said exactly once (a replaced child's at most once).
/// Each failure names its seed. Round two's ordering (the verdict read before the close) fails on these same seeds.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyPropertyTests {
    static let seeds: [UInt64] = Array(1...200)
    static let steps = 150

    @Test func everyEntryIsAnnouncedExactlyOnceInOrder() {
        for seed in Self.seeds {
            let failures = Self.run(seed: seed)
            #expect(failures.isEmpty, "seed \(seed): \(failures.joined(separator: "; "))")
        }
    }

    /// The model is strong enough to find key 2's window: decided from answers read before the close (81593b3's
    /// ordering), some seed plays "privacy on" over a refusal the close absorbed. The first is printed.
    @Test func roundTwosOrderingIsCaught() {
        let failing = Self.seeds.first { !Self.run(seed: $0, ordering: .roundTwo).isEmpty }
        if let failing {
            print("round two's ordering fails at seed \(failing): \(Self.run(seed: failing, ordering: .roundTwo))")
        }
        #expect(failing != nil)
    }

    /// The derived bound (start + ack + margin) only ends a wait no deadline ended: a child that starts just before
    /// its start deadline, or its fresh one (an entry after the first lapsed unwished), and never acks, is refused by
    /// its own ack deadline, and the entry says `unacknowledged`, not `timeout`. A 12 s bound would refuse it first.
    @Test(arguments: [0.0, 11.0]) func theBoundEndsOnlyWhatNoDeadlineEnded(enterAt: Double) {
        let world = PrivacySimWorld()
        world.spawn(.v3, writeFails: false, replacing: nil)
        world.advance(by: enterAt)
        world.enter()
        world.advance(by: 9.9)
        world.start(world.children[0])
        world.advance(by: 30)
        world.finish()
        #expect(world.failures.isEmpty && Self.check(world).isEmpty, "\(world.failures + Self.check(world))")
        #expect(world.entries[1]?.tokens == " unacknowledged")
        #expect(world.played == [.stop(1), .unavailable(1)])
    }

    static func run(seed: UInt64, ordering: PrivacySimWorld.Ordering = .closeFirst) -> [String] {
        var random = SeededGenerator(state: seed)
        let world = PrivacySimWorld(ordering: ordering)
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

    /// Time (firing deadlines and the bound), a crash or reap, a drain, a spawn or reload, a refusal handler.
    static func worldStep(_ world: PrivacySimWorld, _ action: Int, _ child: PrivacySimChild?,
                          _ random: inout SeededGenerator) {
        switch action {
        case 6:
            if Bool.random(using: &random), let child { return world.start(child) }
            world.advance(by: Double.random(in: 0.1...2, using: &random))
        case 7: world.advance(by: Double.random(in: 2...9, using: &random))
        case 8: child.map(world.end)
        case 9:
            guard let child else { return }
            (child.listening, child.drained) = (false, true)
            child.duck.markRetired()
        case 10:
            let kind: PrivacySimChild.Kind = Int.random(in: 0..<4, using: &random) == 0 ? .v2 : .v3
            let old = Bool.random(using: &random) ? world.live.first(where: \.listening) : nil
            world.spawn(kind, writeFails: Int.random(in: 0..<12, using: &random) == 0, replacing: old)
        default: world.runHandler(Int.random(in: 0..<max(1, world.handlers.count), using: &random))
        }
    }

    /// A refused start, the close, the verdict and the chain as separate steps, and a quick off then on.
    static func chainStep(_ world: PrivacySimWorld, _ action: Int, _ child: PrivacySimChild?,
                          _ random: inout SeededGenerator) {
        switch action {
        case 12: if Int.random(in: 0..<3, using: &random) == 0 { world.refuseStart() }
        case 13: world.close()
        case 14: world.verdict()
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
        world.verdict()
        world.play()
    }

    /// The invariants over the ordered clip sequence, after the bound.
    static func check(_ world: PrivacySimWorld) -> [String] {
        var failures: [String] = []
        let clips = world.played
        for entry in world.entries.keys.sorted() {
            let said = clips.filter { $0 == .on(entry) || $0 == .unavailable(entry) || $0 == .withdrawn(entry) }
            if said.count != 1 { failures.append("entry \(entry) played \(said.count) clips") }
            if said == [.withdrawn(entry)], !world.withdrawn.contains(entry) {
                failures.append("entry \(entry) silent though not withdrawn")
            }
            guard let index = clips.firstIndex(where: { $0 == .on(entry) || $0 == .unavailable(entry) }) else {
                continue
            }
            if index == 0 || clips[index - 1] != .stop(entry) {
                failures.append("entry \(entry) clip without its stop")
            }
            if clips[index] == .on(entry) { failures += refusalsAfter(entry, at: index, in: world) }
        }
        for child in world.children where child.killed {
            guard case .refused? = child.duck.settled else { continue }
            let said = child.said + child.claimed
            if child.replaced ? said > 1 : said != 1 {
                failures.append("child \(child.index) refusal said \(said) times")
            }
        }
        return failures
    }

    /// A refusal said after entry `entry`'s "privacy on" must be one decided after its close (or of a child it never
    /// counted): an earlier one would leave "privacy on" claiming what that refusal already undid.
    static func refusalsAfter(_ entry: Int, at index: Int, in world: PrivacySimWorld) -> [String] {
        guard let state = world.entries[entry], let closed = state.closedTick else { return [] }
        return world.played[(index + 1)...].compactMap { clip in
            guard case .own(let child) = clip, child >= 0 else { return nil }
            let refused = world.children[child]
            guard refused.refusedTick < closed, state.opened.contains(where: { $0 === refused }) else { return nil }
            return "entry \(entry)'s privacy on outlived child \(child)'s earlier refusal"
        }
    }
}
#endif
