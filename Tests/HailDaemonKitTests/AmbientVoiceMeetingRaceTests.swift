#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode (rightyo#227) review round 1: a clip privacy supersedes, a same-profile renewal, and a command
/// after teardown. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceMeetingRaceTests {
    /// Review round 1: an on clip still queued when privacy begins is superseded, never heard after "Privacy on".
    /// The latch holds the meeting chain, so the clip is decided only after privacy's own clip has played.
    @Test func privacyRightAfterAnEntrySupersedesItsClip() async throws {
        let rig = try await MeetingRig(clips: MeetingRig.privacyClips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router, listener = rig.env.listener
        #expect(await eventually { router.activePipeline?.childStarted == true }, "privacy child started marker")
        let latch = MeetingLatch()
        router.meetingChanges.enqueue { await latch.wait() }
        #expect(router.setMeeting(on: true, profile: .rubberDuck, connection: connection, reason: "voice") == 1)
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        router.enqueuePrivacyClip(connection) { _ in {
            _ = await router.confirmVoiceMute(AmbientStopConfirmation.privacyOn, on: connection, listener: listener)
        } }
        #expect(try await rig.confirmation() == MeetingRig.privacyOn.text)
        latch.open()
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_meeting_confirmed") == ["on=true profile=meeting confirm=confirmmeetingon/0:sent",
                                                             "on=true profile=rubberDuck confirm=superseded"])
        try await barrier(on: rig.socket, step: "no meeting clip after privacy")
        // The MM-C hook still hears every change, in order.
        #expect(rig.changes == ["on=true profile=meeting reason=voice", "on=true profile=rubberDuck reason=voice",
                                "on=false profile=rubberDuck reason=privacy"])
        await rig.finish()
    }

    /// Review round 1, as media mode: a same-profile entry rearms the timeout (the old expiry is stale) and replays
    /// the on clip as status, keeping the original start, with no second hook: nothing really changed.
    @Test func sameProfileReentryRearmsAndReplaysWithoutAHook() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router
        let first = try #require(router.state.withLock { $0.meeting[connection] })
        let (old, started) = (first.token, first.started)
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 1)
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let renewed = try #require(router.state.withLock { $0.meeting[connection] })
        #expect(renewed.token != old && renewed.started == started && renewed.profile == .meeting)
        #expect(router.setMeeting(on: false, connection: connection, reason: "timeout", expected: old) == 0)
        #expect(router.meetingMode(connection: connection))
        await rig.drainMeetingChanges()
        #expect(rig.changes == ["on=true profile=meeting reason=voice"])
        #expect(rig.details("ambient_meeting").last == "on=true profile=meeting reason=voice reported=1 renewed=true")
        let heard = "on=true profile=meeting confirm=confirmmeetingon/0:sent"
        #expect(rig.details("ambient_meeting_confirmed") == [heard, heard])
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, true) },
                "renewed meeting child marker")
        await rig.finish()
    }

    /// Review round 1: a meeting command a retiring child says after its connection was torn down is refused. No
    /// timer, no child write, no hook and no clip; the closed mark goes with that child.
    @Test func aMeetingCommandAfterTeardownDoesNothing() async throws {
        let rig = try await MeetingRig(phrases: ["meeting mode off", "meeting mode"])
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil }, "late meeting connection marker")
        let connection = try #require(rig.connection()), router = rig.env.router
        rig.pair.close()
        #expect(await eventually { router.state.withLock { $0.closed.contains(connection) } }, "teardown marker")
        try rig.releaseOff()
        #expect(await eventually {
            rig.details("ambient_meeting") == ["on=true profile=meeting reason=voice reported=0 refused=closed"]
        }, "late meeting refusal marker")
        #expect(!router.meetingMode(connection: connection))
        #expect(router.state.withLock { $0.meeting.isEmpty })
        await boundedSettle(router, step: "late meeting child")
        #expect(rig.changes.isEmpty && rig.details("ambient_meeting_confirmed").isEmpty)
        #expect(!((try? rig.fake.recorded("control.txt")) ?? "").contains("media"))
        #expect(router.state.withLock { $0.closed.isEmpty })
        await bounded("late meeting listener") { await rig.env.listener.stop(reason: "synthetic test complete") }
    }
}
#endif
