#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Round 4 of #735 S-8 HS-C end to end, through the router and a fake RightyO: a child a reload registers late in an
/// entry is waited for within its own bound, never killed by the entry's; a voice off racing a device on leaves the
/// clip of the state they decided last; and a child that restores privacy after "unavailable" is announced.
/// Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyRoundFourRigTests {
    typealias Announce = AmbientPrivacyAnnounceTests

    /// A start-private child that confirms its private start only once the test creates `go2`.
    static let heldStartPrivate = """
    \(AmbientPrivacyEntryTests.startPrivatePrelude)
    while [ ! -e go2 ]; do /bin/sleep 0.02; done
    /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \(FakeRightyo.duckV3)
    \(FakeRightyo.ackingTail)
    """

    /// 1. The entry's bound is 6 s here; a reload at about 4 s registers a child that confirms its private start at
    /// about 6.5 s, past the entry's bound but inside its own (6 s from its registration: 3.5 s to spare on a loaded
    /// runner; the old child, which never acks, is not refused by its own ack deadline meanwhile). It is not killed,
    /// nothing is refused, and "privacy on" plays once it confirms. (a8de9f2 killed it at the entry's bound.)
    @Test func aReloadLateInAnEntryIsWaitedForNotKilled() async throws {
        let first = AmbientDuckReloadTests.entry
            .replacingOccurrences(of: FakeRightyo.ackingTail,
                                  with: AmbientPrivacyConfirmAfterAckTests.holdAcks + FakeRightyo.ackingTail)
        let rig = try await DuckRig(script: AmbientDuckReloadTests.staged(first, Self.heldStartPrivate),
                                    clips: AmbientDuckModeTests.clips, confirmTimeout: 6)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let entered = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(4_000))
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(entered.duration(to: .now) < .seconds(6), "the reload must land inside the entry's bound")
        try await Task.sleep(until: entered.advanced(by: .milliseconds(6_500)))
        #expect(rig.details("ambient_duck_confirmed").isEmpty)
        FileManager.default.createFile(atPath: rig.fake.directory.appendingPathComponent("go2").path, contents: nil)
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true playback=idle " + Announce.privacyOn])
        #expect(rig.details("ambient_privacy_start").isEmpty)
    }

    /// The privacy state the clips said last: `on`, `unavailable` or `off`.
    static func lastSaid(_ rig: DuckRig) -> String? {
        rig.details("ambient_duck_confirmed").compactMap { detail in
            detail.hasSuffix(Announce.privacyOn) ? "on" : detail.hasSuffix(Announce.unavailable) ? "unavailable"
                : detail.hasSuffix("confirm=confirmprivacyoff/0:sent") ? "off" : nil
        }.last
    }

    /// 3. A voice off and a device on race, round after round: whichever the router decided last, its clip is the last
    /// one queued, so the last clip always matches the state privacy ended in.
    @Test func aRacingVoiceOffAndDeviceOnEndOnTheirOwnClip() async throws {
        let rig = try await AmbientPrivacySwitchTests.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router
        let voice = router.voiceDuck(on: connection, listener: rig.env.listener)
        for round in 0..<6 {
            router.ambientPrivacy(true, connection: connection)
            #expect(await eventually { router.duckMode(connection: connection) && Self.lastSaid(rig) == "on" })
            await withTaskGroup(of: Void.self) { group in
                group.addTask { voice(.exit) }
                group.addTask { router.ambientPrivacy(true, connection: connection) }
            }
            _ = await rig.settledEvents()
            let expected = router.duckMode(connection: connection) ? "on" : "off"
            #expect(Self.lastSaid(rig) == expected, "round \(round): \(rig.details("ambient_duck_confirmed"))")
            if expected == "on" { voice(.exit) }
            #expect(await eventually { Self.lastSaid(rig) == "off" })
        }
        await rig.finish()
    }

    /// Recovery: privacy on, the only child refused ("unavailable"); a new stream's child then confirms its private
    /// start, which restores privacy, so "privacy on" says so (`reason=recovery`), never a silent change of state.
    @Test func aChildThatRestoresPrivacyIsAnnounced() async throws {
        let first = AmbientPrivacyConfirmAfterAckTests.neverAcked
        let script = "if [ -f first.done ]; then\n\(Self.heldStartPrivate)\nelse\n"
            + "/usr/bin/touch first.done\n\(first)\nfi"
        let rig = try await DuckRig(script: script, clips: AmbientDuckModeTests.clips, ackDeadline: 0.3)
        defer { rig.close() }
        #expect(await eventually { Announce.said(rig) == ["unavailable"] })
        #expect(await eventually { rig.env.router.liveRuns == 0 })
        let connection = try #require(rig.connection())
        #expect(rig.env.router.duckMode(connection: connection))
        FileManager.default.createFile(atPath: rig.fake.directory.appendingPathComponent("go2").path, contents: nil)
        let second = UUID()
        try await recipientSocketSend(audio(second, 0), on: rig.socket)
        #expect(await eventually { Announce.said(rig).count == 2 })
        _ = await rig.settledEvents()
        try await recipientSocketSend(audio(second, 1, final: true), on: rig.socket)
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed").last
            == "on=true reason=recovery still_on playback=idle " + Announce.privacyOn)
    }
}
#endif
