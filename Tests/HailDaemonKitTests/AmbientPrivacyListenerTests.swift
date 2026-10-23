#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Privacy mode's way out through the listener (#735 S-2 round 2): only RightyO's `exit` (or the auto-end, or the
/// connection's end) leaves privacy. An exit while privacy is off is ignored, and nothing a speaker says that slips
/// through while private ever turns it off. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyListenerTests {
    /// `started` (v3) and the owner's "Stop recording.", then one more owner transcript per text (as if it slipped
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
        \(FakeRightyo.ackingControl())
        /usr/bin/sed -n -e '1p' -e '4p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/\(source)/Stop recording./g' \(AmbientPrivacyEventTests.duck(3))\(AmbientPrivacyEventTests.voiceprint)
        \(lines.joined(separator: "\n"))
        \(FakeRightyo.ackingTail)
        """
    }

    /// A stale or duplicate exit while privacy is off: no `setDuck`, no device notice, no clip; a state token only.
    @Test func anExitWhilePrivacyIsOffIsIgnored() async throws {
        let script = FakeRightyo.ackingControl() + "\n" + AmbientPrivacyEventTests.events(["exit"])
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
        let rig = try await DuckRig(script: FakeRightyo.ackingControl() + "\n"
                                        + AmbientPrivacyEventTests.enterThen(["exit", "exit"]),
                                    clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { ["ambient_privacy", "ambient_duck_device"].map { rig.details($0).count } == [1, 2] })
        await rig.finish()
        #expect(rig.details("ambient_privacy") == ["exit=ignored state=off"])
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=voice reported=1"])
        // Not the outcome: the off clip's delivery (#735 flake), or the exit withdrawing the entry silently (#836).
        #expect(rig.details("ambient_duck_confirmed").map { $0.replacing("off/0:refused", with: "off/0:sent")
            .replacing("withdrawn confirm=unreported", with: "playback=idle confirm=confirmprivacyon/0:sent") }
            == ["on=true playback=idle confirm=confirmprivacyon/0:sent", "on=false confirm=confirmprivacyoff/0:sent"])
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
        let on = "playback=idle confirm=confirmprivacyon/0:sent"
        // Round 4 (finding 5): the first entry, still open when the re-entry opened, closes in silence and the
        // re-entry announces the outcome; closed first, it says "privacy on" itself. Either way one clip per state.
        let confirmed = rig.details("ambient_duck_confirmed"), first = confirmed.first ?? ""
        #expect(["on=true " + on, "on=true superseded_by_newer confirm=unreported"].contains(first)
            && confirmed.dropFirst() == ["on=true still_on " + on], "\(confirmed)")
        #expect(rig.details("ambient_privacy").isEmpty)
    }

    /// Privacy taken stops a reply playing first, through the owner's stop path (`stop_playback` to a device that takes
    /// it), then plays only the clip; a refused entry (v2 child: it never acks) leaves playback alone.
    @Test(arguments: [true, false]) func enteringStopsPlaybackARefusalDoesNot(_ taken: Bool) async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true, version: taken ? 3 : 2,
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
        let rig = try await DuckRig(script: FakeRightyo.ackingControl() + "\n/bin/sleep 1\n" + entry,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        #expect(rig.env.router.setMedia(true, connection: connection, reason: "voice") == 1)
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        #expect(rig.env.router.mediaMode(connection: connection) && !rig.env.router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["refused=not_owner confirm=unreported"])
        #expect(rig.details("ambient_duck").isEmpty)
    }

    /// Round 4, then #822 A (Mick: no silent state change): a child that cannot keep privacy is refused and "I can't
    /// listen privately right now." plays when nothing else keeps privacy, a second refused child on the same
    /// connection included: with S-2b both children were launched start-private and did not confirm it. The second
    /// starts after "unavailable", so it is announced as a recovery entry (#735 S-8 HS-C round 4), whose verdict is
    /// "unavailable" again: already the last word, it is not repeated (round 5, the once-guard: `already_unavailable`).
    @Test func theUnavailableClipPlaysOnceForRefusalsInARow() async throws {
        let later = AmbientDuckReloadTests.silent(advertises: true, version: 1)
        let clips = AmbientAckLibrary(clips: ["confirmprivacyon": [AmbientDuckModeTests.clip("Privacy on.", 9)],
                                          "confirmprivacyunavailable": [AmbientDuckModeTests.clip("I can't.", 2)]])
        let rig = try await DuckRig(script: AmbientDuckReloadTests.staged(AmbientDuckReloadTests.entry, later),
                                    clips: clips)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        // The entry is confirmed once the first child acked it (#735 S-8 HS-C), before the reload retires it.
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 1 })
        let connection = try #require(rig.connection())
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        // A new stream on the same connection starts another child that cannot keep privacy.
        try await recipientSocketSend(audio(UUID(), 0), on: rig.socket)
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 3 })
        #expect(rig.env.router.duckMode(connection: connection))
        await rig.finish()
        let said = "confirm=confirmprivacyunavailable/0:sent", rest = rig.details("ambient_duck_confirmed").dropFirst()
        #expect(Array(rest) == ["unavailable " + said, silentRecovery])
        #expect(rig.details("ambient_privacy_start") == Array(repeating: "outcome=refused reason=unconfirmed",
                                                              count: 2))
    }

    /// Round 4 (key 2): a transcript is not addressed to the assistant, so the owner's partial command there gives
    /// no hint and no clip, and nothing changes.
    @Test func anUnaddressedPartialGivesNoHint() async throws {
        let rig = try await DuckRig(script: FakeRightyo.ackingControl() + "\n" + Self.transcriptOnly(
            "Rightyo, stop listening to him, he is wrong."), clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        try await Task.sleep(for: .milliseconds(300))
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed").isEmpty && rig.details("ambient_duck").isEmpty)
    }

    /// Round 3 B2: the owner role's entry without a live voiceprint is refused audibly, never in silence: its own clip
    /// when recorded, else "Nothing was sent.". Privacy stays off and nothing is written to the child.
    @Test(arguments: [true, false]) func anUnverifiedOwnerHearsTheRefusal(_ recorded: Bool) async throws {
        var clips = AmbientDuckModeTests.clips
        if recorded {
            clips = AmbientAckLibrary(clips: ["confirmprivacyrefused": [AmbientDuckModeTests.clip("I couldn't.", 4)],
                                              "confirmnotsent": [AmbientDuckModeTests.clip("Nothing was sent.", 5)]])
        }
        let rig = try await DuckRig(script: FakeRightyo.ackingControl() + "\n" + AmbientPrivacyEntryTests.fixture(
            saying: "Rightyo, stop recording.", advertises: true, roleSource: nil), clips: clips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == (recorded ? "I couldn't." : "Nothing was sent."))
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        await rig.finish()
        let clip = recorded ? "confirmprivacyrefused/0:sent" : "confirmnotsent/0:sent"
        #expect(rig.details("ambient_duck_confirmed") == ["refused=unverified_owner confirm=\(clip)"])
        #expect(rig.details("ambient_duck").isEmpty)
        #expect(try rig.fake.recorded("control.txt") == "")
    }

    /// Round 3 B3(b): the owner's "stop recording, …" that goes on is held back and answered with the hint clip;
    /// nothing changes.
    @Test func theOwnersPartialCommandHearsTheHint() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording the meeting.", advertises: true,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "To go private, say stop recording on its own.")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["hint confirm=confirmprivacyhint/0:sent"])
        #expect(rig.details("ambient_duck").isEmpty)
    }

    /// `started` (v3) and the owner's transcript of `words` (from a voiceprint) only, then `stopped`: no attention and
    /// no request, so nothing addressed it to the assistant.
    static func transcriptOnly(_ words: String) -> String {
        """
        /usr/bin/sed -n -e '1p' -e '4p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/Rightyo, archive the project./\(words)/g' \(AmbientPrivacyEventTests.duck(3)) \
          \(AmbientPrivacyEventTests.voiceprint)
        \(FakeRightyo.ackingTail)
        """
    }
}
/// A silent recovery entry (#735 S-8 HS-C round 5): its "unavailable" would repeat the last word.
private let silentRecovery = "on=true reason=recovery refused already_unavailable confirm=unreported"
#endif
