#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// A property test of the entry announcement (#735 S-8 HS-C round 2), over the real duck controls and the router's own
/// verdict and announcement, with seeded random schedules: start timing (before the entry, after it, or never), ack
/// timing (prompt, late, never, excess), a failed on-write, a crash between write and ack, draining children and
/// reloads, a re-entry while on, and quick off/on. After every entry exactly one of "privacy on" or "unavailable"
/// plays (or none, only when an off withdrew it), never "privacy on" while a listening child has not proved it, and
/// every refusal is said exactly once (a replaced or draining child's at most once: it hears nothing). Each failure
/// names its seed.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyPropertyTests {
    static let seeds: [UInt64] = Array(1...200)
    static let steps = 40

    @Test func everyEntryIsAnnouncedExactlyOnce() {
        for seed in Self.seeds {
            let failures = Self.run(seed: seed)
            #expect(failures.isEmpty, "seed \(seed): \(failures.joined(separator: "; "))")
        }
    }

    static func run(seed: UInt64) -> [String] {
        var random = SeededGenerator(state: seed)
        let world = PrivacySimWorld()
        world.spawn(.v3, writeFails: false, replacing: nil)
        for _ in 0..<steps { step(world, &random) }
        // The bound: every entry still open is announced, and every refused child's handler runs.
        for entry in world.entries.keys.sorted() { world.resolve(entry, timeout: true) }
        while !world.handlers.isEmpty { world.runHandler() }
        return world.failures + check(world)
    }

    static func step(_ world: PrivacySimWorld, _ random: inout SeededGenerator) {
        let action = Int.random(in: 0..<14, using: &random)
        guard action < 8 else { return connectionStep(world, action, &random) }
        let child = world.live.randomElement(using: &random)
        switch action {
        case 0, 1: world.enter()
        case 2: world.exit()
        case 3: child.map(world.start)
        case 4, 5: child.map(world.ack)
        case 6: child.map(world.ackDeadline)
        default: child.map(world.startDeadline)
        }
    }

    /// The connection's own steps: a crash, a drain, a spawn or reload, a handler, an answer or the bound.
    static func connectionStep(_ world: PrivacySimWorld, _ action: Int, _ random: inout SeededGenerator) {
        let child = world.live.randomElement(using: &random)
        switch action {
        case 8: child.map(world.end)
        case 9: if let child { (child.listening, child.drained) = (false, true) }
        case 10:
            let kind = PrivacySimChild.Kind.allCases.randomElement(using: &random) ?? .v3
            let old = Bool.random(using: &random) ? world.children.first(where: \.listening) : nil
            world.spawn(kind, writeFails: Int.random(in: 0..<5, using: &random) == 0, replacing: old)
        case 11: world.runHandler()
        case 12: world.entries.keys.sorted().forEach { world.resolve($0, timeout: false) }
        default: world.entries.filter(\.value.open).keys.min().map { world.resolve($0, timeout: true) }
        }
    }

    /// The invariants after the bound.
    static func check(_ world: PrivacySimWorld) -> [String] {
        var failures: [String] = []
        for (entry, state) in world.entries.sorted(by: { $0.key < $1.key }) {
            if state.open { failures.append("entry \(entry) never announced") }
            // Silent only once an off (itself announced, "Recording again.") ended privacy while it was open.
            let clips = (state.clip == nil ? 0 : 1) + state.refusalClips
            if clips > 1 { failures.append("entry \(entry) said \(clips) clips") }
            if clips == 0, !state.offWhileOpen {
                failures.append("entry \(entry) silent (\(state.answer.map(\.token) ?? "none"))")
            }
        }
        for (index, child) in world.children.enumerated() {
            guard child.killed, case .refused? = child.duck.settled else { continue }
            let said = child.said + child.claimed
            if child.replaced || child.drained ? said > 1 : said != 1 {
                failures.append("child \(index) refusal said \(said) times")
            }
        }
        return failures
    }
}
#endif
