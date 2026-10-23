#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// Recovery and the off race (#735 S-8 HS-C round 4, the third key), directed on the property model: the router's own
/// ledger over real duck controls, deterministically.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyRecoveryTests {
    typealias Property = AmbientPrivacyPropertyTests

    /// Privacy on and kept by one child, which an excess ack then refuses: "unavailable" is the last word.
    static func unavailable() -> PrivacySimWorld {
        let world = PrivacySimWorld()
        world.spawn(.v3, writeFails: false, replacing: nil)
        world.start(world.children[0])
        world.enter()
        world.ackOwed(world.children[0])
        Property.progress(world)
        world.ack(world.children[0])
        Property.progress(world)
        #expect(world.played == [.stop(1), .on(1), .own(0)])
        return world
    }

    /// No flapping: three start-private children register inside one recovery entry's life (a new stream, its reload,
    /// another new stream), each confirming its private start. They join the one recovery entry: one "privacy on".
    @Test func severalChildrenJoinOneRecoveryEntry() {
        let world = Self.unavailable()
        world.spawn(.v3, writeFails: false, replacing: nil)
        world.advance(by: 1)
        world.spawn(.v3, writeFails: false, replacing: world.children[1])
        world.advance(by: 1)
        world.spawn(.v3, writeFails: false, replacing: nil)
        #expect(world.recoveries == [2] && world.ledger.entries[2]?.members.count == 3)
        world.children[1...].forEach(world.start)
        world.finish()
        let failures = world.failures + Property.check(world)
        #expect(failures.isEmpty, "\(failures)")
        #expect(world.played == [.stop(1), .on(1), .own(0), .stop(2), .on(2)])
        #expect(world.decided[2]?.tokens == " still_on")
    }

    /// Proof before recovery: a start-private child that registers but never confirms its start, or starts without
    /// keeping privacy, never makes the recovery entry say "privacy on". Refused at its own start deadline (or at its
    /// `started`), nothing keeps privacy, so by rule (c) the recovery entry says "unavailable" (`refused`).
    @Test(arguments: [PrivacySimChild.Kind.v3, .v2]) func aRecoveryNeedsTheChildsProof(_ kind: PrivacySimChild.Kind) {
        let world = Self.unavailable()
        world.spawn(kind, writeFails: false, replacing: nil)
        #expect(world.recoveries == [2])
        if kind == .v2 { world.start(world.children[1]) }
        world.finish()
        let failures = world.failures + Property.check(world)
        #expect(failures.isEmpty, "\(failures)")
        #expect(world.played == [.stop(1), .on(1), .own(0), .stop(2), .unavailable(2)])
        #expect(world.decided[2]?.tokens == " refused" && world.children[1].claimed == 1)
    }

    /// The off race: a refusal decided while private (a reload's child past its start deadline) whose handler runs
    /// after an off is silent (`superseded_by_off`): "Recording again." stays the last word.
    @Test func aRefusalAfterTheOffSaysNothing() {
        let world = PrivacySimWorld()
        world.spawn(.v3, writeFails: false, replacing: nil)
        world.start(world.children[0])
        world.enter()
        world.ackOwed(world.children[0])
        Property.progress(world)
        world.spawn(.v3, writeFails: false, replacing: world.children[0])
        world.advance(by: PrivacySimWorld.startDeadline + 0.1)
        #expect(world.handlers.count == 1)
        world.exit()
        world.runHandler(0)
        world.finish()
        let failures = world.failures + Property.check(world)
        #expect(failures.isEmpty, "\(failures)")
        #expect(world.played == [.stop(1), .on(1), .off] && world.children[1].silenced == 1)
    }

    /// The new assertions catch what they guard: a recovery "privacy on" right after another, and "unavailable" after
    /// the last off.
    @Test func theNewAssertionsBite() {
        let world = PrivacySimWorld()
        world.recoveries = [2]
        world.played = [.stop(1), .on(1), .stop(2), .on(2), .off, .own(0)]
        let failures = Property.recoveryAndOff(world)
        #expect(failures.count == 2, "\(failures)")
    }
}
#endif
