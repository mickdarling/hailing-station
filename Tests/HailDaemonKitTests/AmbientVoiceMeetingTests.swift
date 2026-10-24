#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #735 meeting mode (rightyo#227): whole-turn commands and the owner's authority. Synthetic phrases only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceMeetingTests {
    static let names: Set<String> = ["rightyo", "jarvis"]

    @Test(arguments: Array(VoiceMeeting.meetingPhrases))
    func meetingPhrases(_ phrase: String) {
        #expect(VoiceMeeting.command(in: "Hey Jarvis, please \(phrase), please!", names: Self.names) == .on(.meeting))
    }

    @Test(arguments: Array(VoiceMeeting.rubberDuckPhrases))
    func rubberDuckPhrases(_ phrase: String) {
        #expect(VoiceMeeting.command(in: "Okay Rightyo, \(phrase).", names: Self.names) == .on(.rubberDuck))
    }

    @Test(arguments: Array(VoiceMeeting.offPhrases))
    func offPhrases(_ phrase: String) {
        #expect(VoiceMeeting.command(in: "Jarvis, \(phrase) please.", names: Self.names) == .off)
    }

    @Test(arguments: ["don't start the meeting", "we need meeting mode", "meeting mode for tomorrow",
                       "Siri, meeting mode", "Jarvis", "", "stop recording", "privacy mode", "go private"])
    func otherTurnsAreRequests(_ phrase: String) {
        #expect(VoiceMeeting.command(in: phrase, names: Self.names) == nil)
    }

    @Test func confirmationKeysAreReservedAndCannotSayAPrivacyExit() throws {
        #expect(AmbientRightyoRouter.defaultMeetingTimeout == 3 * 3600)
        let keys: Set<String> = [AmbientStopConfirmation.meetingOn, AmbientStopConfirmation.meetingOff,
                                 AmbientStopConfirmation.meetingEnded, AmbientStopConfirmation.rubberDuckOn,
                                 AmbientStopConfirmation.rubberDuckOff]
        #expect(keys.isSubset(of: AmbientStopConfirmation.reserved))
        for clip in [MeetingRig.on, MeetingRig.off, MeetingRig.ended] {
            let text = try #require(clip.text).lowercased()
            for exit in ["i'm back", "start listening", "privacy off"] { #expect(!text.contains(exit)) }
        }
    }

    @Test func phrasesNeverCollideWithPrivacy() {
        let phrases = VoiceMeeting.meetingPhrases.union(VoiceMeeting.rubberDuckPhrases).union(VoiceMeeting.offPhrases)
        for phrase in phrases {
            for forbidden in ["stop", "privacy", "private", "recording"] { #expect(!phrase.contains(forbidden)) }
            for turn in [phrase, "Hey Jarvis, please \(phrase) please."] {
                #expect(PrivacyEntry.match(turn, names: Self.names) == nil)
            }
        }
    }

    /// Both transcript and decision must say owner; without the descriptor a phrase is an ordinary request.
    @Test(arguments: [("owner", true, 0), ("participant", true, 1), ("decision", true, 1),
                       ("unlabelled", true, 1), ("owner", false, 1)])
    func onlyAnOwnersControlledTurnIsHeld(_ role: String, _ control: Bool, _ delivered: Int) async throws {
        var fixture = AmbientWiringVoiceMuteTests.fixture(saying: "Rightyo, meeting mode.", enrolled: true)
        let demote = switch role {
        case "participant": #"-e 's/"role": "owner"/"role": "participant"/g'"#
        case "decision": #"-e 's/"system", "role": "owner"/"system", "role": "participant"/'"#
        case "unlabelled": #"-e 's/, "role": "owner"//g'"#
        default: ""
        }
        fixture = fixture.replacingOccurrences(of: "events.jsonl\n/bin/cat", with: "\(demote) events.jsonl\n/bin/cat")
        let fake = try FakeRightyo(fixture)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let seen = Mutex<[MeetingProfile?]>([])
        var settings = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20))
        settings.replyControl = control
        settings.onVoiceMeeting = { on, profile in
            #expect(on)
            seen.withLock { $0.append(profile) }
        }
        let pipeline = try RightyoAmbientPipeline(configuration: settings, dispatcher: RecordingAmbientDispatcher())
        pipeline.finishInput()
        await bounded("meeting command pipeline") {
            do { #expect(try await pipeline.run().delivered == delivered) } catch { Issue.record(error) }
        }
        #expect(seen.withLock { $0 } == (delivered == 0 ? [.meeting] : []))
    }

    /// Review round 1: MM-C records a meeting, so its commands need an enrolled session and the owner's turn, as a
    /// note does. On an anonymous session the phrase is an ordinary request; media and mute stay as they are.
    @Test(arguments: [(true, "Rightyo, meeting mode."), (true, "Rightyo, end the meeting."),
                       (false, "Rightyo, meeting mode."), (false, "Rightyo, end the meeting.")])
    func meetingCommandsNeedAnEnrolledOwner(_ enrolled: Bool, _ words: String) async throws {
        let fake = try FakeRightyo(AmbientWiringVoiceMuteTests.fixture(saying: words, enrolled: enrolled))
        defer { fake.cleanUp() }
        try fake.install(fixture: enrolled ? "enrolled-formed-request.jsonl" : "tool-events.jsonl")
        let seen = Mutex<[Bool]>([])
        var settings = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20))
        settings.replyControl = true
        settings.onVoiceMeeting = { on, _ in seen.withLock { $0.append(on) } }
        let pipeline = try RightyoAmbientPipeline(configuration: settings, dispatcher: RecordingAmbientDispatcher())
        pipeline.finishInput()
        await bounded("meeting speakers pipeline") {
            do { #expect(try await pipeline.run().delivered == (enrolled ? 0 : 1)) } catch { Issue.record(error) }
        }
        #expect(seen.withLock { $0 } == (enrolled ? [words.contains("end") == false] : []))
    }

    @Test func ownerOnThenOffReachesChildrenAndPlaysClipsInOrder() async throws {
        let rig = try await MeetingRig(phrases: ["meeting mode", "meeting mode off"])
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection())
        #expect(rig.env.router.meetingMode(connection: connection))
        try rig.releaseOff()
        #expect(try await rig.confirmation() == MeetingRig.off.text)
        #expect(await eventually { rig.changes.count == 2 }, "owner on/off hook marker")
        #expect(rig.changes == ["on=true profile=meeting reason=voice", "on=false profile=meeting reason=voice"])
        #expect(rig.changeConnections == [connection, connection])
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, false) },
                "owner on/off child marker")
        #expect(!rig.env.router.meetingMode(connection: connection))
        #expect(await rig.env.rig.adapter.contexts.isEmpty)
        #expect(await eventually { rig.details("ambient_meeting_confirmed").count == 2 }, "owner clip log marker")
        #expect(rig.details("ambient_meeting_confirmed") == [
            "on=true profile=meeting confirm=confirmmeetingon/0:sent",
            "on=false profile=meeting confirm=confirmmeetingoff/0:sent"
        ])
        await rig.finish()
    }

    @Test func rubberDuckUsesMeetingFallbackClips() async throws {
        let rig = try await MeetingRig(phrases: ["rubber duck mode", "rubber duck mode off"])
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        try rig.releaseOff()
        #expect(try await rig.confirmation() == MeetingRig.off.text)
        #expect(await eventually { rig.changes.count == 2 }, "rubber duck hook marker")
        #expect(rig.changes == ["on=true profile=rubberDuck reason=voice", "on=false profile=rubberDuck reason=voice"])
        await rig.finish()
    }
}
#endif
