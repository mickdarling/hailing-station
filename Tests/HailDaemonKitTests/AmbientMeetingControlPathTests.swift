#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 MM-D (rightyo#227): every path that changes a meeting tells a meeting-capable child, beside its media gate:
/// timeout, privacy, the media hand-off, reloads and new children. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientMeetingControlPathTests {
    static let entry = MeetingLines.lines(MeetingLines.meeting(true), MeetingLines.media(true))
    static let exit = MeetingLines.lines(MeetingLines.media(false), MeetingLines.meeting(false))

    @Test func aTimeoutTellsTheChildMeetingOffAfterTheGate() async throws {
        let rig = try await MeetingRig(meeting: MeetingLines.advert)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router
        let token = try #require(router.state.withLock { $0.meeting[connection]?.token })
        #expect(router.setMeeting(on: false, connection: connection, reason: "timeout", expected: token) == 1)
        #expect(try await rig.confirmation() == MeetingRig.ended.text)
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == Self.entry + Self.exit },
                "timeout lines marker")
        await rig.finish()
    }

    @Test func privacyEndingTheMeetingTellsTheChildMeetingOff() async throws {
        let rig = try await MeetingRig(meeting: MeetingLines.advert)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(await eventually { router.activePipeline?.childStarted == true }, "privacy child started marker")
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        #expect(!router.meetingMode(connection: connection) && router.duckMode(connection: connection))
        let lines = Self.entry + "{\"duck\":true}\n" + Self.exit
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == lines }, "privacy lines marker")
        await rig.drainMeetingChanges()
        #expect(rig.changes.last == "on=false profile=meeting reason=privacy")
        #expect(rig.details("ambient_meeting_control") == ["meeting_control=true", "meeting_control=true"])
        await rig.finish()
    }

    /// Media taking over keeps the gate and then ends the meeting control; the meeting taking back is on before it.
    @Test func theMediaHandOffKeepsTheGateAroundTheMeetingLine() async throws {
        let rig = try await MeetingRig(meeting: MeetingLines.advert)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(router.setMedia(true, connection: connection, reason: "voice") == 1)
        #expect(router.setMeeting(on: true, profile: .rubberDuck, connection: connection, reason: "voice") == 1)
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let lines = Self.entry + MeetingLines.lines(MeetingLines.media(true), MeetingLines.meeting(false)) + Self.entry
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == lines }, "hand-off lines marker")
        await rig.finish()
    }

    @Test func aReloadedChildDuringAMeetingGetsBothLines() async throws {
        let rig = try await MeetingRig(meeting: MeetingLines.advert)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        try rig.quietLaterChildren()
        let router = rig.env.router
        await bounded("meeting control reload") { #expect(await router.reload() == .reloaded) }
        #expect(await eventually {
            MeetingLines.newChild(try? rig.fake.recorded("control.txt"), after: Self.entry)
        }, "reloaded capable child marker")
        #expect(rig.changes == ["on=true profile=meeting reason=voice"])
        await rig.finish()
    }

    @Test func aNewChildDuringAMeetingGetsBothLines() async throws {
        let rig = try await MeetingRig(meeting: MeetingLines.advert)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        try rig.quietLaterChildren()
        try await recipientSocketSend(audio(rig.stream, 1, final: true), on: rig.socket)
        await boundedSettle(rig.env.router, step: "meeting control first child ended")
        let next = UUID()
        try await recipientSocketSend(audio(next, 0), on: rig.socket)
        #expect(await eventually {
            MeetingLines.newChild(try? rig.fake.recorded("control.txt"), after: Self.entry)
        }, "new capable child marker")
        try await recipientSocketSend(audio(next, 1, final: true), on: rig.socket)
        await rig.finish()
    }

    /// A restore onto a meeting-capable child tells it the meeting too; the dropped child got nothing more.
    @Test func aRestoredMeetingTellsTheNewCapableChild() async throws {
        let rig = try await RestoreRig(meeting: MeetingLines.advert)
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        let (socket, _) = try await rig.start()
        #expect(await eventually { MeetingLines.newChild(rig.control(2)) }, "restored capable child marker")
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        await rig.finish()
        #expect(rig.control(1) == Self.entry && MeetingLines.newChild(rig.control(2)))
    }

    /// A move from a stale live holder likewise; the old holder's child keeps both lines, never written off.
    @Test func aMovedMeetingTellsTheNewChildAndLeavesTheOldOneGated() async throws {
        let rig = try await RestoreRig(meeting: MeetingLines.advert)
        defer { rig.close() }
        let (first, _) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        #expect(await eventually { rig.control(1) == Self.entry }, "holder lines marker")
        let (socket, _) = try await rig.start()
        #expect(await eventually { MeetingLines.newChild(rig.control(2)) }, "moved capable child marker")
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        await rig.drainMeetingChanges()
        #expect(rig.changes.map(\.reason) == ["voice", "moved", "resumed"])
        await rig.finish()
        #expect(rig.control(1) == Self.entry)
    }

    /// N4: a start no longer current, while a meeting is held elsewhere, is told meeting on before its gate.
    @Test func aStartNoLongerCurrentIsToldMeetingOnBeforeTheGate() async throws {
        let rig = try await RestoreRig(phrase: nil, meeting: MeetingLines.advert)
        defer { rig.close() }
        let (_, listening) = try await rig.start()
        let router = rig.router, pipeline = try #require(rig.router.activePipeline)
        #expect(await eventually { pipeline.childStarted }, "listening child started marker")
        let (_, holder) = try await rig.connect()
        #expect(router.setMeeting(on: true, connection: holder, reason: "voice") == 0)
        router.state.withLock { router.carryModes(to: UUID(), stream: UUID(), pipeline: pipeline, in: &$0) }
        #expect(await eventually { rig.control(1) == Self.entry }, "late capable child marker")
        #expect(!router.meetingMode(connection: listening) && router.meetingMode(connection: holder))
        await rig.drainMeetingChanges(clips: [holder])
        await rig.finish()
        #expect(rig.control(1) == Self.entry)
    }

    /// The fail-safe when the meeting line cannot be taken: a capable child whose `started` has not come is written no
    /// meeting line (`reportMeeting` is false), yet its gate is written at once and counted, so the meeting is
    /// reported and quiet. The meeting line follows its `started`, after the gate, which nothing undid.
    @Test func aMeetingLineNotTakenStillLeavesTheGate() async throws {
        let rig = try await RestoreRig(phrase: nil, meeting: MeetingLines.advert, holdStarted: true)
        defer { rig.close() }
        let (_, connection) = try await rig.start()
        let router = rig.router, pipeline = try #require(rig.router.activePipeline)
        #expect(!pipeline.childStarted)
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 1)
        #expect(!pipeline.reportMeeting(true) && !pipeline.meetingHeld(true))
        #expect(await eventually { rig.control(1) == RestoreRig.gate }, "gate before started marker")
        #expect(router.meetingMode(connection: connection))
        try Data().write(to: rig.fake.directory.appendingPathComponent("go"))
        #expect(await eventually { rig.control(1) == RestoreRig.gate + MeetingLines.meeting(true) },
                "meeting line after started marker")
        #expect(pipeline.meetingHeld(true))
        await rig.finish()
        #expect(rig.control(1) == RestoreRig.gate + MeetingLines.meeting(true))
    }
}
#endif
