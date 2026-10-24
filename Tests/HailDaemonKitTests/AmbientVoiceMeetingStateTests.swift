#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode (rightyo#227): host state, child writes, the MM-C seam and bounded lifecycle races. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceMeetingStateTests {
    @Test func privacyEntryEndsMeetingWithoutAnExtraClip() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(await eventually { router.activePipeline?.childStarted == true }, "privacy child started marker")
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        #expect(!router.meetingMode(connection: connection) && router.duckMode(connection: connection))
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 0)
        #expect(await eventually { rig.changes.count == 2 }, "privacy meeting end hook marker")
        #expect(rig.changes.last == "on=false profile=meeting reason=privacy")
        let lines = MeetingRig.lines(true) + "{\"duck\":true}\n" + MeetingRig.lines(false)
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == lines }, "privacy child writes marker")
        // Review round 1: only once the chain has drained does "no meeting clip" mean anything.
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_meeting_confirmed") == ["on=true profile=meeting confirm=confirmmeetingon/0:sent"])
        try await barrier(on: rig.socket, step: "no meeting clip after privacy")
        await rig.finish()
    }

    @Test func privateMeetingEntryHearsOnlyTheAnnouncedPrivacyStatus() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Privacy on. I'm only listening for my name.")
        _ = try await receiveFrame(on: rig.socket, step: "privacy on audio")
        let connection = try #require(rig.connection()), router = rig.env.router
        router.voiceMeeting(on: connection, listener: rig.env.listener)(true, .rubberDuck)
        #expect(try await rig.confirmation() == "Privacy on. I'm only listening for my name.")
        #expect(await eventually {
            rig.details("ambient_meeting_confirmed") == [
                "on=true profile=rubberDuck confirm=confirmprivacystatus/0:sent"
            ]
        }, "privacy status confirmation marker")
        #expect(router.duckMode(connection: connection) && !router.meetingMode(connection: connection))
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == "{\"duck\":true}\n" },
                "refused meeting child marker")
        await rig.finish()
    }

    @Test func mediaAndMeetingHandOffWithoutAFalseWrite() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(router.setMedia(true, connection: connection, reason: "voice") == 1)
        #expect(router.mediaMode(connection: connection) && !router.meetingMode(connection: connection))
        #expect(router.setMeeting(on: true, profile: .rubberDuck, connection: connection, reason: "voice") == 1)
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        #expect(router.meetingMode(connection: connection) && !router.mediaMode(connection: connection))
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, true, true) },
                "exclusive hand-off child marker")
        #expect(await eventually { rig.changes.count == 3 }, "exclusive hand-off hook marker")
        #expect(rig.changes == ["on=true profile=meeting reason=voice", "on=false profile=meeting reason=media",
                                "on=true profile=rubberDuck reason=voice"])
        // The confirmation log follows the clip's send, after the hook: waited for itself, then the chain drained.
        #expect(await eventually { rig.details("ambient_meeting_confirmed").count == 2 }, "hand-off clip log marker")
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_meeting_confirmed") == ["meeting", "rubberDuck"].map {
            "on=true profile=\($0) confirm=confirmmeetingon/0:sent"
        })
        await rig.finish()
    }

    @Test func timeoutEndsTheMeetingAndPlaysEnded() async throws {
        let rig = try await MeetingRig(timeout: 0.5)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        #expect(try await rig.confirmation() == MeetingRig.ended.text)
        let connection = try #require(rig.connection())
        #expect(!rig.env.router.meetingMode(connection: connection))
        #expect(await eventually { rig.changes.count == 2 }, "timeout hook marker")
        #expect(rig.changes.last == "on=false profile=meeting reason=timeout")
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, false) },
                "timeout child marker")
        await rig.finish()
    }

    @Test func staleTimeoutAndAbsentExitDoNothing() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router
        let old = try #require(router.state.withLock { $0.meeting[connection]?.token })
        #expect(router.setMeeting(on: false, connection: connection, reason: "voice") == 1)
        #expect(router.setMeeting(on: false, connection: connection, reason: "voice") == 0)
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 1)
        #expect(router.setMeeting(on: false, connection: connection, reason: "timeout", expected: old) == 0)
        #expect(try await rig.confirmation() == MeetingRig.off.text)
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        #expect(await eventually { rig.changes.count == 3 }, "stale timer hook marker")
        #expect(router.meetingMode(connection: connection))
        #expect(router.state.withLock { $0.meeting[connection]?.token } != old)
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, false, true) },
                "stale timer child marker")
        await rig.finish()
    }

    @Test func reloadedChildStartsWithMediaTrue() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        try rig.quietLaterChildren()
        let connection = try #require(rig.connection()), router = rig.env.router
        let token = router.state.withLock { $0.meeting[connection]?.token }
        await bounded("meeting child reload") { #expect(await router.reload() == .reloaded) }
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, true) },
                "reloaded meeting child marker")
        #expect(router.state.withLock { $0.meeting[connection]?.token } == token)
        #expect(rig.changes == ["on=true profile=meeting reason=voice"])
        await rig.finish()
    }

    @Test func newChildOnTheConnectionStartsWithMediaTrue() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        try rig.quietLaterChildren()
        try await recipientSocketSend(audio(rig.stream, 1, final: true), on: rig.socket)
        await boundedSettle(rig.env.router, step: "meeting first child ended")
        let next = UUID()
        try await recipientSocketSend(audio(next, 0), on: rig.socket)
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, true) },
                "new meeting child marker")
        #expect(rig.changes == ["on=true profile=meeting reason=voice"])
        try await recipientSocketSend(audio(next, 1, final: true), on: rig.socket)
        await rig.finish()
    }

    @Test func connectionTeardownEndsMeetingOnce() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection())
        rig.pair.close()
        #expect(await eventually { rig.changes.count == 2 }, "connection meeting end hook marker")
        #expect(!rig.env.router.meetingMode(connection: connection))
        rig.env.router.stop(connection: connection)
        #expect(rig.changes == ["on=true profile=meeting reason=voice", "on=false profile=meeting reason=connection"])
        await boundedSettle(rig.env.router, step: "disconnected meeting child")
        await bounded("disconnected meeting listener") {
            await rig.env.listener.stop(reason: "synthetic test complete")
        }
    }

    @Test func missingClipsNeverUndoTheMode() async throws {
        let rig = try await MeetingRig(clips: nil)
        defer { rig.close() }
        #expect(await eventually {
            rig.details("ambient_meeting_confirmed") == ["on=true profile=meeting confirm=no_clips"]
        }, "missing clip log marker")
        let connection = try #require(rig.connection())
        #expect(rig.env.router.meetingMode(connection: connection))
        await rig.finish()
    }
}
#endif
