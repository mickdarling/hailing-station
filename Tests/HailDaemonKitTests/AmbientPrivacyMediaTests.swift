#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Privacy and media mode (#735, Mick round 2): privacy entry ends media mode, but media mode never ends privacy.
/// Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyMediaTests {
    /// Round 2: media mode never ends privacy. While private, a media-mode entry is refused and nothing changes or
    /// reaches the child; the spoken one hears the privacy status clip instead of "Media mode on.".
    @Test func mediaModeNeverEndsPrivacy() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Privacy on. I'm only listening for my name.")
        _ = try await receiveFrame(on: rig.socket, step: "privacy on audio")
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(router.setMedia(true, connection: connection, reason: "voice") == 0)
        #expect(router.duckMode(connection: connection) && !router.mediaMode(connection: connection))
        router.voiceMedia(on: connection, listener: rig.env.listener)(true)
        #expect(try await rig.confirmation() == "Privacy on. I'm only listening for my name.")
        #expect(await eventually {
            rig.details("ambient_media_confirmed") == ["on=true confirm=confirmprivacystatus/0:sent"]
        })
        #expect(router.duckMode(connection: connection) && !router.mediaMode(connection: connection))
        #expect(rig.details("ambient_media") == ["on=true reason=voice reported=0 refused=private",
                                                 "on=true reason=voice reported=0 refused=private"])
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == "{\"duck\":true}\n" })
        await rig.finish()
    }

    /// Privacy entry while in media mode still ends media mode, in the child and in the host's state.
    @Test func privacyEntryEndsMediaMode() async throws {
        let rig = try await DuckRig(script: AmbientPrivacyReplyQuiet.script)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(await eventually { router.setMedia(true, connection: connection, reason: "voice") == 1 })
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        #expect(router.duckMode(connection: connection) && !router.mediaMode(connection: connection))
        let lines = ["{\"media\":true}", "{\"duck\":true}", "{\"media\":false}"]
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == lines.map { $0 + "\n" }.joined() })
        await rig.finish()
    }
}

/// A fake that takes control lines and forms one ordinary synthetic request, advertising `duck` v2.
enum AmbientPrivacyReplyQuiet {
    static let script = "/bin/cat <&3 > control.txt &\n"
        + AmbientPrivacyEntryTests.fixture(saying: "Rightyo, archive the project.", advertises: true)
}
#endif
