#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// "I can't listen privately right now." (#822 A, Mick: no silent state change), by the state rule (#735 S-8 HS-C
/// round 4): a refusal is said if and only if, after it, no listening child keeps privacy. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyUnavailableTests {
    typealias Ledger = AmbientPrivacyLedger<AmbientPrivacyCloseFirstTests.Child>
    static let started = AmbientPrivacyCloseFirstTests.started

    /// A started v3 child refused (an excess ack) with no entry open.
    static func refused() -> AmbientDuckControl {
        let duck = AmbientDuckControl()
        _ = duck.observe(started: started, write: { _ in true })
        _ = duck.report(true, write: { _ in true })
        #expect(duck.acknowledge() == .counted && duck.acknowledge() == .excess && duck.refuseIfWished())
        return duck
    }

    /// A child keeping privacy (acked), or one whose proof is still to come.
    static func holder(proved: Bool) -> AmbientDuckControl {
        let duck = AmbientDuckControl()
        _ = duck.observe(started: started, write: { _ in true })
        _ = duck.report(true, write: { _ in true })
        if proved { _ = duck.acknowledge() }
        return duck
    }

    /// The rule, both ways, and every silence named: said when nothing keeps privacy after it; silent while a
    /// listening child keeps it or may (`superseded_by_keep`), after an off (`superseded_by_off`), and once said.
    @Test func aRefusalIsSaidOnlyWhenItChangesTheState() {
        var ledger = Ledger()
        #expect(ledger.refusal(of: Self.refused(), on: true, holders: [Self.holder(proved: true)])
            == (false, "unavailable=superseded_by_keep"))
        #expect(ledger.refusal(of: Self.refused(), on: true, holders: [Self.holder(proved: false)])
            == (false, "unavailable=superseded_by_keep"))
        #expect(ledger.refusal(of: Self.refused(), on: false, holders: []) == (false, "unavailable=superseded_by_off"))
        #expect(ledger.said == nil)
        let duck = Self.refused()
        #expect(ledger.refusal(of: duck, on: true, holders: [duck]) == (true, nil))
        #expect(ledger.said == .unavailable)
        #expect(ledger.refusal(of: duck, on: true, holders: []) == (false, "unavailable=said_by_entry"))
        // A start refused while private (no child): said the same way; while off, it is no privacy event at all.
        #expect(ledger.refusal(of: nil, on: true, holders: []) == (true, nil))
        #expect(ledger.refusal(of: nil, on: false, holders: []) == (false, nil))
    }

    /// While an entry is open, the newest announces the outcome: the refusal is carried to it, never said twice.
    @Test func anOpenEntryTakesARefusalOver() throws {
        var ledger = Ledger()
        let keeper = Self.holder(proved: false)
        _ = ledger.open(on: [(AmbientPrivacyCloseFirstTests.Child(), keeper)], wasOn: true, at: 0)
        #expect(ledger.refusal(of: Self.refused(), on: true, holders: [])
            == (false, "unavailable=said_by_entry carried"))
        #expect(keeper.acknowledge() == .counted)
        guard case .decided(let decision) = ledger.close(1, now: 0, bound: 16, listening: { _ in true }) else {
            Issue.record("entry 1 still waits")
            return
        }
        #expect(decision.clip == AmbientStopConfirmation.privacyOn && decision.tokens == " still_on superseded_by_keep")
    }

    /// Through the router (finding 2): the child's privacy state is held by its closure, not its pipeline, so a
    /// refusal an entry already claimed stays claimed once there is no pipeline at all, and nothing is said twice.
    @Test func aClaimedRefusalStaysSaidWithoutItsPipeline() async throws {
        let rig = try await DuckRig(script: AmbientDuckReloadTests.silent(advertises: true),
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        let duck = AmbientDuckControl(startPrivate: true)
        duck.open(entry: 1)
        #expect(duck.expire())
        #expect(duck.close(entry: 1, refusePending: false).claimed)
        let mark = AmbientRunMark()
        mark.set(duck)
        let say = rig.env.router.voiceDuck(on: connection, listener: rig.env.listener, mark: mark)
        say(.unavailable)
        say(.unavailable)
        _ = await rig.settledEvents()
        #expect(rig.details("ambient_privacy") == ["unavailable=said_by_entry", "unavailable=said_by_entry"])
        #expect(rig.details("ambient_duck_confirmed").isEmpty)
        await rig.finish()
    }

    /// Through the router: privacy off, a late refusal plays nothing ("Recording again." is the last word); privacy on
    /// and the stream's child taking it, another child's refusal plays nothing either (`superseded_by_keep`).
    @Test func aRefusalAfterTheOffOrBesideAKeeperIsSilent() async throws {
        let rig = try await AmbientPrivacySwitchTests.startedRig()
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        let mark = AmbientRunMark()
        mark.set(Self.refused())
        rig.env.router.voiceDuck(on: connection, listener: rig.env.listener, mark: mark)(.unavailable)
        #expect(await eventually { rig.details("ambient_privacy") == ["unavailable=superseded_by_off"] })
        #expect(await eventually { rig.env.router.activePipeline?.childStarted == true })
        #expect(rig.env.router.setDuck(true, connection: connection, reason: "voice") == 1)
        let other = AmbientRunMark()
        other.set(Self.refused())
        rig.env.router.voiceDuck(on: connection, listener: rig.env.listener, mark: other)(.unavailable)
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(rig.details("ambient_privacy") == ["unavailable=superseded_by_off", "unavailable=superseded_by_keep"])
        #expect(rig.details("ambient_duck_confirmed") == [AmbientPrivacySwitchTests.statusOff])
    }
}
#endif
