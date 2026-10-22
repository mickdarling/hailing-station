#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Privacy mode's way out through the listener (#735 S-2 round 2): only RightyO's `exit` (or the auto-end, or the
/// connection's end) leaves privacy. An exit while privacy is off is ignored, and nothing a speaker says that slips
/// through while private ever turns it off. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyListenerTests {
    /// `started` (v2) and the owner's "Stop recording.", then one more owner transcript per text (as if it slipped
    /// through while private), then `stopped`.
    static func slips(_ texts: [String]) -> String {
        let source = "Rightyo, archive the project."
        let lines = texts.enumerated().map { index, text in
            "/usr/bin/sed -n -e '4p' events.jsonl | /usr/bin/sed -e \"s/formed-demo/$7/g\" -e 's/\(source)/\(text)/g' "
                + AmbientPrivacyEventTests.voiceprint + " "
                + #"-e 's/"sequence": 4/"sequence": \#(index + 5)/' "#
                + #"-e 's/"utterance_id": "request"/"utterance_id": "slip-\#(index)"/'"#
        }
        return """
        /bin/cat <&3 > control.txt &
        /usr/bin/sed -n -e '1p' -e '4p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/\(source)/Stop recording./g' \(AmbientPrivacyEventTests.duck(2))\(AmbientPrivacyEventTests.voiceprint)
        \(lines.joined(separator: "\n"))
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" -e 's/"sequence": 7/"sequence": 99/'
        """
    }

    /// A stale or duplicate exit while privacy is off: no `setDuck`, no device notice, no clip; a state token only.
    @Test func anExitWhilePrivacyIsOffIsIgnored() async throws {
        let script = "/bin/cat <&3 > control.txt &\n" + AmbientPrivacyEventTests.events(["exit"])
        let rig = try await DuckRig(script: script,
                                    clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { !rig.details("ambient_privacy").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_privacy") == ["exit=ignored state=off"])
        #expect(rig.details("ambient_duck").isEmpty && rig.details("ambient_duck_device").isEmpty)
        #expect(rig.details("ambient_duck_confirmed").isEmpty)
        #expect(try rig.fake.recorded("control.txt") == "")
    }

    @Test func aDuplicateExitIsIgnored() async throws {
        let rig = try await DuckRig(script: "/bin/cat <&3 > control.txt &\n"
                                        + AmbientPrivacyEventTests.enterThen(["exit", "exit"]),
                                    clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { !rig.details("ambient_privacy").isEmpty })
        #expect(await eventually { rig.details("ambient_duck_device").count == 2 })
        await rig.finish()
        #expect(rig.details("ambient_privacy") == ["exit=ignored state=off"])
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=voice reported=1"])
        #expect(rig.details("ambient_duck_confirmed") == ["on=true playback=idle confirm=confirmprivacyon/0:sent",
                                                          "on=false confirm=confirmprivacyoff/0:sent"])
    }

    /// Defence in depth: while private, "stop", "stop that", "stop listening" or "Rightyo, stop" slipping through
    /// never turns privacy off. "stop listening" is an entry, answered "still on"; nothing else acts.
    @Test func noStopLikePhraseEverLeavesPrivacy() async throws {
        let rig = try await DuckRig(script: Self.slips(["stop", "stop that", "stop listening", "Rightyo, stop."]),
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        let connection = try #require(rig.connection())
        #expect(rig.env.router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=true reason=voice reported=1"])
        #expect(rig.details("ambient_duck_confirmed") == ["on=true playback=idle confirm=confirmprivacyon/0:sent",
                                                          "on=true playback=idle confirm=confirmprivacyon/0:sent"])
        #expect(rig.details("ambient_privacy").isEmpty)
    }

    /// Privacy taken stops a reply playing first, through the owner's stop path (`stop_playback` to a device that takes
    /// it), then plays only the clip; a refused entry (v1 child) leaves playback alone.
    @Test(arguments: [true, false]) func enteringStopsPlaybackARefusalDoesNot(_ taken: Bool) async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true, version: taken ? 2 : 1,
                                    clips: AmbientDuckModeTests.clips, capabilities: [PlaybackStop.capability])
        defer { rig.close() }
        var payloads: [FramePayload] = []
        while payloads.allSatisfy({ if case .text = $0 { false } else { true } }) {
            payloads.append(try await receiveFrame(on: rig.socket, step: "entry").payload)
        }
        #expect(payloads.contains(.control(.stopPlayback)) == taken)
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        await rig.finish()
        let token = taken ? "on=true playback=stopped confirm=confirmprivacyon/0:sent"
            : "on=true refused=unsupported_version confirm=confirmnotsent/0:sent"
        #expect(rig.details("ambient_duck_confirmed") == [token])
    }

    /// A guest's entry never enters and never ends media mode: refused, no clip, logged `refused=not_owner`.
    @Test func aGuestsEntryLeavesMediaModeOn() async throws {
        let entry = AmbientPrivacyEntryTests.fixture(saying: "Rightyo, stop recording.", guest: true, advertises: true)
        let rig = try await DuckRig(script: "/bin/cat <&3 > control.txt &\n/bin/sleep 1\n" + entry,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        #expect(rig.env.router.setMedia(true, connection: connection, reason: "voice") == 1)
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        #expect(rig.env.router.mediaMode(connection: connection) && !rig.env.router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true refused=not_owner confirm=unreported"])
        #expect(rig.details("ambient_duck").isEmpty)
    }

    /// A reload to a child that cannot keep privacy (#735 S-2b: launched start-private, not confirmed) is killed and
    /// refused: privacy stays on, so no "Recording again." clip and no off reach the device.
    @Test func aReloadThatCannotKeepPrivacyIsRefusedAndPrivacyStays() async throws {
        let later = AmbientDuckReloadTests.silent(advertises: true, version: 1)
        let rig = try await DuckRig(script: AmbientDuckReloadTests.staged(AmbientDuckReloadTests.entry, later),
                                    clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(await eventually { rig.details("ambient_privacy_start") == ["outcome=refused reason=unconfirmed"] })
        #expect(rig.env.router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed").count == 1)
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1"])
    }
}
#endif
