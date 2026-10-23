#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// Round 5 of #735 S-8 HS-C on the property model: every entry decides within its cap (its opening + 2 × bound: 36 s),
/// even under a registration storm (reloads or new streams faster than any child proves), and "unavailable" is said
/// once while it is the last word. 9b33a76 had no cap (`uncapped`): a storm kept its entry waiting past it.
extension AmbientPrivacyPropertyTests {
    static let stormSeeds: [UInt64] = Array(1...200)
    /// The first storm seed 9b33a76's uncapped close fails on (recorded from `theStormFindsTheMissingCap`).
    static let recordedStorm: UInt64 = 4

    /// A storm: an entry, then registrations every 1 to 9 s (inside the 18 s bound, so some child's proof is always
    /// still to come) until well past the cap, with no proof among them; closes, plays, handlers and refused starts
    /// at random between them. Then each live child proves or not, and everything settles.
    static func storm(seed: UInt64, faults: PrivacySimFaults = []) -> [String] {
        var random = SeededGenerator(state: seed)
        let world = PrivacySimWorld(faults: faults)
        world.spawn(.v3, writeFails: false, replacing: nil)
        world.start(world.children[0])
        world.enter()
        world.advance(by: Double.random(in: 0.1...1, using: &random))
        while world.time < PrivacySimWorld.cap + 10 {
            let kind: PrivacySimChild.Kind = Int.random(in: 0..<4, using: &random) == 0 ? .v2 : .v3
            world.spawn(kind, writeFails: false, replacing: Bool.random(using: &random) ? world.hearing.first : nil)
            switch Int.random(in: 0..<5, using: &random) {
            case 0: Self.progress(world)
            case 1: world.runHandler(0)
            case 2: world.refuseStart()
            default: break
            }
            world.advance(by: Double.random(in: 1...9, using: &random))
        }
        for child in world.live where Bool.random(using: &random) { world.start(child) }
        world.finish()
        return world.failures + Self.check(world)
    }

    @Test func everyStormDecidesWithinTheCap() {
        for seed in Self.stormSeeds {
            let failures = Self.storm(seed: seed)
            #expect(failures.isEmpty, "storm seed \(seed): \(failures.joined(separator: "; "))")
        }
    }

    /// The model finds 9b33a76's missing cap: the first failing storm seed is printed, and it is the one recorded.
    @Test func theStormFindsTheMissingCap() {
        let failing = Self.stormSeeds.first { !Self.storm(seed: $0, faults: .uncapped).isEmpty }
        if let failing {
            print("9b33a76 uncapped fails at storm seed \(failing): \(Self.storm(seed: failing, faults: .uncapped))")
        }
        #expect(failing == Self.recordedStorm)
        let failures = Self.storm(seed: Self.recordedStorm, faults: .uncapped)
        #expect(failures.contains { $0.contains("past its cap") }, "\(failures)")
        #expect(Self.storm(seed: Self.recordedStorm).isEmpty)
    }

    /// Directed: reloads every 8 s from 1 s, none of their children starting. At the cap (36 s) the entry says
    /// "unavailable" (`timeout cap`) and kills no child whose own bound has not passed (the reload at 33 s); that child
    /// goes on in a recovery entry, proves at 41 s, and "privacy on" plays once. Uncapped, the entry still waits.
    @Test(arguments: [PrivacySimFaults(), .uncapped]) func aStormIsCappedThenRecovers(_ faults: PrivacySimFaults) {
        let world = PrivacySimWorld(faults: faults)
        world.spawn(.v3, writeFails: false, replacing: nil)
        world.start(world.children[0])
        world.enter()
        world.advance(by: 1)
        while world.time < 40 {
            world.spawn(.v3, writeFails: false, replacing: world.hearing.first)
            world.advance(by: 8)
            world.close()
        }
        let late = world.children[5]
        #expect(late.listening && world.time == 41)
        guard faults.isEmpty else {
            #expect(world.failures.contains { $0.contains("entry 1 still waits") }, "\(world.failures)")
            return
        }
        #expect(world.decided[1]?.clip == AmbientStopConfirmation.privacyUnavailable)
        #expect(world.decided[1]?.tokens == " timeout cap" && world.ledger.said == .unavailable)
        #expect(world.recoveries == [2] && !late.killed)
        world.play()
        world.start(late)
        world.finish()
        let failures = world.failures + Self.check(world)
        #expect(failures.isEmpty, "\(failures)")
        #expect(world.played == [.stop(1), .unavailable(1), .stop(2), .on(2)], "\(world.played)")
    }

    /// The once-guard: privacy on, its only child gone, then refused starts in a row (busy, stopping): exactly one
    /// "unavailable"; every later one is silent (`already_unavailable`) while it is the last word.
    @Test func refusedStartsInARowSayUnavailableOnce() {
        let world = PrivacySimWorld()
        world.spawn(.v3, writeFails: false, replacing: nil)
        world.start(world.children[0])
        world.enter()
        world.ackOwed(world.children[0])
        Self.progress(world)
        world.end(world.children[0])
        for _ in 0..<4 { world.refuseStart() }
        world.finish()
        #expect(world.played == [.stop(1), .on(1), .own(-1)])
        #expect((world.failures + Self.check(world)).isEmpty)
    }
}
#endif
