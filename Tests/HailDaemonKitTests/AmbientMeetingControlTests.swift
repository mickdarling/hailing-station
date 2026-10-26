#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 MM-D (rightyo#227): RightyO's dedicated meeting control, `{"meeting": true|false}`, written only to a child
/// whose `started` advertised `"meeting": {"version": 1}`, beside the unchanged `{"media": …}` gate. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientMeetingControlTests {
    static func started(_ meeting: String?) -> Data {
        let advert = FakeRightyo.meetingAdvert(meeting)
        return Data(#"{"type": "session", "phase": "started", \#(advert)"schema_version": 1}"#.utf8)
    }

    @Test(arguments: [(MeetingLines.advert, true), (nil, false), (#"{"version": 2}"#, false),
                      (#"{"version": "1"}"#, false), (#"{"version": true}"#, false), ("true", false), ("{}", false),
                      ("1", false), (#"[{"version": 1}]"#, false)] as [(String?, Bool)])
    func onlyVersionOneAdvertises(_ meeting: String?, _ advertised: Bool) {
        #expect(AmbientMeetingControl.advertises(Self.started(meeting)) == advertised)
    }

    /// A wish before `started` is kept, then written only to a child that advertised the control; a line is written
    /// only when it changes what the child was told.
    @Test(arguments: [true, false])
    func aWishIsWrittenOnlyToAnAdvertisingChild(_ advertised: Bool) {
        let control = AmbientMeetingControl()
        var written: [Bool] = []
        #expect(!control.report(true) { _ in
            Issue.record("written before started")
            return true
        })
        let advert = advertised ? MeetingLines.advert : nil
        control.observe(started: Self.started(advert)) { written.append($0); return true }
        control.observe(started: Self.started(MeetingLines.advert)) { written.append($0); return true }
        #expect(control.report(true) { written.append($0); return true } == advertised)
        #expect(control.report(false) { written.append($0); return true } == advertised)
        #expect(control.report(false) { written.append($0); return true } == advertised)
        #expect(written == (advertised ? [true, false] : []))
        #expect(control.holds(false) == advertised && !control.holds(true))
    }

    /// The fail-safe at the control: a dropped meeting line is never claimed as held, and the next report tries again.
    @Test func aDroppedLineIsNeverClaimedAndIsTriedAgain() {
        let control = AmbientMeetingControl()
        var tries: [Bool] = []
        control.observe(started: Self.started(MeetingLines.advert)) { _ in
            Issue.record("nothing was wished yet")
            return true
        }
        #expect(!control.report(true) { tries.append($0); return false })
        // Never told on, the child holds meeting off (its own default), never the dropped on.
        #expect(!control.holds(true) && control.holds(false))
        #expect(control.report(true) { tries.append($0); return true })
        #expect(control.holds(true) && tries == [true, true])
    }

    @Test func aMeetingCapableChildIsToldMeetingOnBeforeTheGateAndOffAfterIt() async throws {
        let rig = try await MeetingRig(phrases: ["meeting mode", "meeting mode off"], meeting: MeetingLines.advert)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let entry = MeetingLines.lines(MeetingLines.meeting(true), MeetingLines.media(true))
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == entry }, "meeting entry lines marker")
        try rig.releaseOff()
        #expect(try await rig.confirmation() == MeetingRig.off.text)
        let exit = entry + MeetingLines.lines(MeetingLines.media(false), MeetingLines.meeting(false))
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == exit }, "meeting exit lines marker")
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_meeting_control") == ["meeting_control=true", "meeting_control=true"])
        #expect(rig.details("ambient_meeting") == ["on=true profile=meeting reason=voice reported=1",
                                                   "on=false profile=meeting reason=voice reported=1"])
        await rig.finish()
    }

    /// No advertisement, or one haild does not know, is today's behaviour exactly: media lines only.
    @Test(arguments: [nil, #"{"version": 2}"#, "true"] as [String?])
    func aChildWithoutTheAdvertisementGetsOnlyTheGate(_ meeting: String?) async throws {
        let rig = try await MeetingRig(phrases: ["meeting mode", "meeting mode off"], meeting: meeting)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        try rig.releaseOff()
        #expect(try await rig.confirmation() == MeetingRig.off.text)
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, false) },
                "media-only child marker")
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_meeting_control") == ["meeting_control=false", "meeting_control=false"])
        await rig.finish()
        #expect(try rig.fake.recorded("control.txt") == MeetingRig.lines(true, false))
    }

    /// The coordinator's requirement: a child that advertised the meeting control but never takes it (it sets every
    /// meeting line aside) still holds the media gate for the whole meeting, never a media false until it ends. The
    /// meeting, its report and its clips are unchanged: only the gate counts as reported.
    @Test func aChildThatIgnoresTheMeetingLineKeepsTheGate() async throws {
        let rig = try await MeetingRig(phrases: ["meeting mode", "meeting mode off"], meeting: MeetingLines.advert,
                                       ignoring: true)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(await eventually { (try? rig.fake.recorded("ignored.txt")) == MeetingLines.meeting(true) },
                "meeting line set aside marker")
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true) }, "gate marker")
        // A renewal mid-meeting writes the gate again, never lowers it; the child was already told meeting on.
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 1)
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, true) },
                "renewed gate marker")
        #expect(router.meetingMode(connection: connection))
        #expect(try rig.fake.recorded("ignored.txt") == MeetingLines.meeting(true))
        try rig.releaseOff()
        #expect(try await rig.confirmation() == MeetingRig.off.text)
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, true, false) },
                "gate lowered only at the end marker")
        #expect(await eventually {
            (try? rig.fake.recorded("ignored.txt")) == MeetingLines.lines(MeetingLines.meeting(true),
                                                                          MeetingLines.meeting(false))
        }, "meeting off set aside marker")
        await rig.drainMeetingChanges()
        let on = "on=true profile=meeting confirm=confirmmeetingon/0:sent"
        let off = "on=false profile=meeting confirm=confirmmeetingoff/0:sent"
        #expect(rig.details("ambient_meeting_confirmed") == [on, on, off])
        #expect(rig.details("ambient_meeting").first == "on=true profile=meeting reason=voice reported=1")
        await rig.finish()
    }
}
#endif
