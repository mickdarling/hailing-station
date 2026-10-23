#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// A status asked while a privacy entry is still unproven (#735 6362119223): decided when its clip plays, behind the
/// entry, so it never says privacy is on unless "Privacy on" was said. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyStatusTests {
    /// Behind an entry that said "unavailable" (its only child exited before the ack), the status is not on.
    @Test func aStatusBehindAnUnavailableEntryIsNotOn() async throws {
        let script = AmbientPrivacyEventTests.enterThen(["status"], acked: false)
            .replacingOccurrences(of: FakeRightyo.ackingTail, with: "IFS= read -r ctl <&3\nexit 3\n")
        let rig = try await DuckRig(script: script, clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == [
            "on=true ended playback=idle " + AmbientPrivacyAnnounceTests.unavailable,
            "status on=false confirm=unreported"
        ])
    }

    /// Behind a proven entry, the status says privacy is on, after "Privacy on".
    @Test func aStatusAfterAProvenEntrySaysOn() async throws {
        let rig = try await DuckRig(script: FakeRightyo.ackingControl() + "\n"
                                        + AmbientPrivacyEventTests.enterThen(["status"]),
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == [
            "on=true playback=idle " + AmbientPrivacyAnnounceTests.privacyOn,
            "status on=true confirm=confirmprivacystatus/0:sent"
        ])
    }

    /// A media-mode entry refused while privacy is armed but unproven (#839 keys): its status clip is decided behind
    /// the entry, which says "unavailable" here, so it is silent and never says privacy is on.
    @Test func aMediaRefusalBeforeTheAckNeverSaysPrivacyOn() async throws {
        let rig = try await DuckRig(script: AmbientPrivacyConfirmAfterAckTests.neverAcked,
                                    clips: AmbientDuckModeTests.clips, ackDeadline: 0.5)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        rig.env.router.voiceMedia(on: connection, listener: rig.env.listener)(true)
        #expect(await eventually { !rig.details("ambient_media_confirmed").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_media_confirmed") == ["on=true confirm=unreported"])
        #expect(rig.details("ambient_media") == ["on=true reason=voice reported=0 refused=private"])
        #expect(!rig.details("ambient_duck_confirmed").contains { $0.contains("confirmprivacyon") })
        #expect(rig.details("ambient_duck_confirmed").contains { $0.hasSuffix("confirmprivacyunavailable/0:sent") })
    }
}
#endif
