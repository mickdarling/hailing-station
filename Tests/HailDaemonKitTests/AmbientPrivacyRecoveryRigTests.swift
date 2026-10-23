#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Recovery and the off race (#735 S-8 HS-C round 4, the third key) end to end, through the router and a fake RightyO.
/// Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyRecoveryRigTests {
    typealias Announce = AmbientPrivacyAnnounceTests
    typealias Four = AmbientPrivacyRoundFourRigTests

    /// The first launch enters privacy and never acks (refused at its 0.3 s ack deadline: "unavailable"); every later
    /// launch runs `later`.
    static func rig(_ later: String, startDeadline: TimeInterval = RightyoAmbientPipeline.defaultStartDeadline)
        async throws -> DuckRig {
        let first = AmbientPrivacyConfirmAfterAckTests.neverAcked
        let script = "if [ -f first.done ]; then\n\(later)\nelse\n/usr/bin/touch first.done\n\(first)\nfi"
        let rig = try await DuckRig(script: script, clips: AmbientDuckModeTests.clips, startDeadline: startDeadline,
                                    ackDeadline: 0.3)
        #expect(await eventually { Announce.said(rig) == ["unavailable"] })
        #expect(await eventually { rig.env.router.liveRuns == 0 })
        return rig
    }

    /// No flapping: a new stream's child, then two reloads of it, all start-private and held, register inside one
    /// recovery entry's life; then each confirms. One "privacy on", from the recovery entry.
    @Test func severalRegistrationsSayPrivacyOnOnce() async throws {
        let rig = try await Self.rig(Four.heldStartPrivate)
        defer { rig.close() }
        let second = UUID()
        try await recipientSocketSend(audio(second, 0), on: rig.socket)
        #expect(await eventually { rig.env.router.activePipeline != nil })
        for _ in 0..<2 {
            #expect(await eventually { await rig.env.router.reload() == .reloaded })
        }
        FileManager.default.createFile(atPath: rig.fake.directory.appendingPathComponent("go2").path, contents: nil)
        #expect(await eventually { Announce.said(rig).count == 2 })
        _ = await rig.settledEvents()
        try await recipientSocketSend(audio(second, 1, final: true), on: rig.socket)
        await rig.finish()
        #expect(Announce.said(rig) == ["unavailable", "on"])
        #expect(rig.details("ambient_duck_confirmed").filter { $0.contains("reason=recovery") }
            == ["on=true reason=recovery still_on playback=idle " + Announce.privacyOn])
    }

    /// Proof before recovery: a start-private child that never says `started` (refused at its own 0.5 s start
    /// deadline), or says it without `private: true` (refused at once), never gets "privacy on". Nothing keeps privacy,
    /// so by rule (c) the recovery entry's verdict is "unavailable" (`refused`); already the last word, it is not said
    /// again (round 5: `already_unavailable`).
    @Test(arguments: [false, true]) func aRecoveryNeedsTheChildsProof(_ startsPublic: Bool) async throws {
        let later = startsPublic
            ? "/usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e \"s/formed-demo/$7/g\" \(FakeRightyo.duckV3)\n"
                + FakeRightyo.ackingTail
            : "/bin/cat > /dev/null\n"
        let rig = try await Self.rig(later, startDeadline: 0.5)
        defer { rig.close() }
        let second = UUID()
        try await recipientSocketSend(audio(second, 0), on: rig.socket)
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(Announce.said(rig) == ["unavailable"])
        #expect(rig.details("ambient_duck_confirmed").last
            == "on=true reason=recovery refused already_unavailable confirm=unreported")
    }

    /// Round 5, the cap, end to end: the bound is 4 s here (cap 8 s). Reloads every 2 s from 1.5 s keep some child's
    /// proof still to come, so only the cap decides the entry: "unavailable" (`timeout cap`), no child killed. The
    /// latest child goes on in a recovery entry, and "privacy on" plays once it confirms.
    @Test func aReloadStormIsCappedThenRecovers() async throws {
        let first = AmbientDuckReloadTests.entry
            .replacingOccurrences(of: FakeRightyo.ackingTail,
                                  with: AmbientPrivacyConfirmAfterAckTests.holdAcks + FakeRightyo.ackingTail)
        let rig = try await DuckRig(script: AmbientDuckReloadTests.staged(first, Four.heldStartPrivate),
                                    clips: AmbientDuckModeTests.clips, confirmTimeout: 4)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let entered = ContinuousClock.now
        for step in 1...4 {
            try await Task.sleep(until: entered.advanced(by: .milliseconds(step * 2_000 - 500)))
            #expect(await rig.env.router.reload() == .reloaded)
        }
        #expect(await eventually { Announce.said(rig) == ["unavailable"] })
        #expect(rig.details("ambient_duck_confirmed") == ["on=true timeout cap playback=idle " + Announce.unavailable])
        #expect(rig.details("ambient_privacy_start").isEmpty)
        FileManager.default.createFile(atPath: rig.fake.directory.appendingPathComponent("go2").path, contents: nil)
        #expect(await eventually { Announce.said(rig).count == 2 })
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(Announce.said(rig) == ["unavailable", "on"])
        #expect(rig.details("ambient_duck_confirmed").last
            == "on=true reason=recovery still_on playback=idle " + Announce.privacyOn)
        #expect(rig.details("ambient_privacy_start").isEmpty)
    }

    /// The off race, directed: a refusal decided while private but handled after the device's off says nothing, so
    /// "Recording again." is the last word while privacy stays off.
    @Test func nothingAfterTheOffImpliesPrivacy() async throws {
        let rig = try await AmbientPrivacySwitchTests.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router
        router.ambientPrivacy(true, connection: connection)
        #expect(await eventually { Four.lastSaid(rig) == "on" })
        let mark = AmbientRunMark()
        mark.set(AmbientPrivacyUnavailableTests.refused())
        router.ambientPrivacy(false, connection: connection)
        router.voiceDuck(on: connection, listener: rig.env.listener, mark: mark)(.unavailable)
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(Four.lastSaid(rig) == "off" && !router.duckMode(connection: connection))
        #expect(rig.details("ambient_privacy") == ["unavailable=superseded_by_off"])
    }
}
#endif
