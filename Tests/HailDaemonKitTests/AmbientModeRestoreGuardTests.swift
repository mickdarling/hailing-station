#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode restore (MM-E), review round 2: recording never spreads to a device that did not record, the
/// stale holder's children are never written, a start no longer current is still gated, and privacy taken anywhere
/// ends every mode daemon-wide. Synthetic devices only; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientModeRestoreGuardTests {
    /// N1: a guest device that inherited the gate unrecorded stays unrecorded through a move and a park, even on its
    /// own claims.
    @Test func aGuestStaysUnrecordedThroughAMoveAndAPark() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, _) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        let (guest, _) = try await rig.start(name: "other", kind: "pad")
        #expect(try await rig.confirmation(on: guest) == RestoreRig.resumed.text)
        let (again, moved) = try await rig.start(name: "other", kind: "pad")
        #expect(try await rig.confirmation(on: again) == RestoreRig.resumed.text)
        #expect(await eventually { rig.changes.count == 5 }, "guest move hook marker")
        await rig.drop(again, moved)
        #expect(rig.parked?.meeting?.recording == false)
        let (_, back) = try await rig.start(name: "other", kind: "pad")
        #expect(await eventually { rig.changes.count == 7 }, "guest park hook marker")
        let resumed = rig.changes.filter { $0.on && $0.reason.hasPrefix("resumed") }
        #expect(resumed.map(\.reason) == Array(repeating: "resumed_unrecorded", count: 3))
        #expect(resumed.allSatisfy { !$0.recording })
        #expect(rig.router.state.withLock { $0.meeting[back]?.recording } == false)
        let decided = rig.details("meeting_restored")
        #expect(decided.count == 3)
        #expect(decided.dropFirst().allSatisfy { $0.contains("recording=false device_match=true") })
        await rig.finish()
    }

    /// N2: a profile switch keeps the meeting's recording state, recorded or not.
    @Test(arguments: [true, false]) func aProfileSwitchKeepsRecording(_ sameDevice: Bool) async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        let (socket, connection) = try await rig.start(name: sameDevice ? "test" : "other")
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(await eventually { rig.changes.count == 3 }, "restore hook marker")
        #expect(rig.router.setMeeting(on: true, profile: .rubberDuck, connection: connection, reason: "voice") == 1)
        #expect(await eventually { rig.changes.count == 4 }, "profile switch hook marker")
        let switched = try #require(rig.changes.last)
        #expect(switched.on && switched.profile == .rubberDuck && switched.recording == sameDevice)
        #expect(switched.meetingID == rig.changes[0].meetingID)
        #expect(rig.router.state.withLock { $0.meeting[connection]?.recording } == sameDevice)
        await rig.finish()
    }

    /// N6: a move writes nothing to the old holder's children, even one still listening, so none is ungated. The
    /// move is driven directly onto a fresh stream, while the holder's own child still runs.
    @Test func aMoveNeverWritesTheOldHoldersChildren() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, holder) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        #expect(await eventually { rig.control(1) == RestoreRig.gate }, "holder gate marker")
        let (router, elsewhere, stream) = (rig.router, UUID(), UUID())
        let pipeline = try #require(router.activePipeline)
        router.state.withLock { state in
            state.latest[elsewhere] = stream
            router.carryModes(to: elsewhere, stream: stream, pipeline: pipeline, in: &state)
            state.latest[elsewhere] = nil
        }
        #expect(!router.meetingMode(connection: holder) && router.meetingMode(connection: elsewhere))
        #expect(await eventually { rig.changes.count == 3 }, "direct move hook marker")
        #expect(rig.changes.map(\.reason) == ["voice", "moved", "resumed_unrecorded"])
        router.setMeeting(on: false, connection: elsewhere, reason: "timeout")
        await rig.finish()
        #expect(rig.control(1) == RestoreRig.gate)
    }

    /// N4: a start no longer current (torn down or superseded mid-launch) takes nothing, but its child is gated
    /// while a mode is held anywhere: no move, no hook, no clip.
    @Test func aStartNoLongerCurrentIsStillGated() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        _ = try await rig.start()
        let (_, holder) = try await rig.connect()
        #expect(rig.router.setMeeting(on: true, connection: holder, reason: "voice") == 0)
        let router = rig.router, pipeline = try #require(rig.router.activePipeline)
        router.state.withLock { router.carryModes(to: UUID(), stream: UUID(), pipeline: pipeline, in: &$0) }
        #expect(await eventually { rig.control(1) == RestoreRig.gate }, "late child gated marker")
        #expect(router.meetingMode(connection: holder) && rig.changes.count == 1)
        #expect(rig.details("ambient_mode_moved").isEmpty && rig.details("meeting_restored").isEmpty)
        await rig.finish()
    }

    /// N5: privacy taken on any connection ends every meeting daemon-wide, live holders included, with no clip; after
    /// privacy ends nothing is held, and a later reconnect restores nothing.
    @Test func privacyAnywhereEndsEveryHeldMeeting() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (_, listening) = try await rig.start()
        let (held, holder) = try await rig.connect()
        #expect(rig.router.setMeeting(on: true, connection: holder, reason: "voice") == 0)
        let router = rig.router
        #expect(await eventually { router.activePipeline?.childStarted == true }, "listening child started marker")
        #expect(router.setDuck(true, connection: listening, reason: "voice") == 1)
        #expect(!router.meetingMode(connection: holder))
        #expect(await eventually { rig.changes.count == 2 }, "privacy ended holder marker")
        #expect(rig.changes.last?.reason == "privacy" && rig.changes.last?.connection == holder)
        let meetingID = try #require(rig.changes.first?.meetingID)
        #expect(await eventually {
            rig.details("ambient_mode_ended") == ["reason=privacy mode=meeting from=\(holder) meeting=\(meetingID)"]
        }, "privacy ended log marker")
        router.setDuck(false, connection: listening, reason: "voice")
        #expect(!router.meetingMode(connection: holder) && !router.meetingMode(connection: listening))
        await rig.drop(held, holder)
        #expect(rig.parked == nil)
        let (_, later) = try await rig.start()
        #expect(!router.meetingMode(connection: later) && rig.details("meeting_restored").isEmpty)
        await rig.finish()
    }
}
#endif
