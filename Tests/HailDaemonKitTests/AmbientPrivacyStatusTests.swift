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
}
#endif
