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
    /// so by rule (c) the recovery entry says "unavailable" (`refused`).
    @Test(arguments: [false, true]) func aRecoveryNeedsTheChildsProof(_ startsPublic: Bool) async throws {
        let later = startsPublic
            ? "/usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e \"s/formed-demo/$7/g\" \(FakeRightyo.duckV3)\n"
                + FakeRightyo.ackingTail
            : "/bin/cat > /dev/null\n"
        let rig = try await Self.rig(later, startDeadline: 0.5)
        defer { rig.close() }
        let second = UUID()
        try await recipientSocketSend(audio(second, 0), on: rig.socket)
        #expect(await eventually { Announce.said(rig).count == 2 })
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(Announce.said(rig) == ["unavailable", "unavailable"])
        #expect(rig.details("ambient_duck_confirmed").last
            == "on=true reason=recovery refused playback=idle " + Announce.unavailable)
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
