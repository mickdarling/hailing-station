#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Close first, then decide (#735 S-8 HS-C round 3), end to end through the router and a fake RightyO: a duplicate
/// ack never leaves "privacy on" as the last word, and an off then on mid-wait keeps the healthy child with one clip
/// per entry, all on the connection's one clip chain. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyCloseFirstRigTests {
    typealias Announce = AmbientPrivacyAnnounceTests

    /// The owner's entry from a child that acks each on-line twice: the second ack is excess, so it is refused.
    static let doubleAck = (FakeRightyo.ackingControl() + "\n" + AmbientPrivacyEventTests.enterThen([]))
        .replacingOccurrences(of: #"/usr/bin/touch "acked.$n""#, with: #"""
        /usr/bin/touch "acked.$n"; n=$((n + 1))
        printf "$ACK_FORMAT" "${ACK_AT_MS:-0}" "$ACK_SID" "$n" "${ACK_EMITTED:-2000}"
        """#)

    /// 1. Whether the duplicate lands before the close (the entry says "unavailable") or after it ("privacy on", then
    /// the child's own "unavailable" on the same chain), "unavailable" is last, and the entry plays one clip.
    @Test func aDuplicateAckNeverLeavesPrivacyOnLast() async throws {
        let rig = try await DuckRig(script: Self.doubleAck, clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { Announce.said(rig).last == "unavailable" })
        _ = await rig.settledEvents()
        await rig.finish()
        let said = Announce.said(rig)
        #expect(said == ["unavailable"] || said == ["on", "unavailable"], "\(said)")
        #expect(rig.details("ambient_duck_confirmed").filter { $0.hasPrefix("on=true") }.count == 1)
    }

    /// 4. Off then on before the child acked: the first entry is withdrawn (silent, logged), "Recording again." plays,
    /// and once the child acks both on-lines the second says "privacy on". The child is never refused.
    @Test func offThenOnMidWaitKeepsTheHealthyChild() async throws {
        let rig = try await DuckRig(script: AmbientPrivacyConfirmAfterAckTests.heldSwitch(),
                                    clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability])
        defer { rig.close() }
        let statusOff = AmbientPrivacySwitchTests.statusOff
        #expect(await eventually { rig.details("ambient_duck_confirmed") == [statusOff] })
        let connection = try #require(rig.connection())
        rig.env.router.ambientPrivacy(true, connection: connection)
        rig.env.router.ambientPrivacy(false, connection: connection)
        rig.env.router.ambientPrivacy(true, connection: connection)
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 3 })
        AmbientPrivacyAckGateTests.go(rig.fake)
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 4 })
        _ = await rig.settledEvents()
        #expect(rig.env.router.liveRuns == 1)
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == [
            statusOff, "on=true reason=device withdrawn confirm=unreported",
            "on=false reason=device confirm=confirmprivacyoff/0:sent",
            "on=true reason=device playback=idle confirm=confirmprivacyon/0:sent"
        ])
        #expect(rig.details("ambient_privacy_start").isEmpty)
    }
}
#endif
