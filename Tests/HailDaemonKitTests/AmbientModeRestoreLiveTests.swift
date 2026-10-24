#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode restore (MM-E round 1, finding 1): haild has no keepalive, so a phone that lost its network can
/// start again on a new connection while its old one still holds the meeting. The mode moves to the new start, under
/// the lock that registers its child, so no child runs ungated while a meeting is on daemon-wide. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientModeRestoreLiveTests {
    @Test func aStaleHolderMovesTheMeetingToTheNewStart() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, stale) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        await rig.drainMeetingChanges()
        let meetingID = try #require(rig.changes.first?.meetingID)
        let (socket, connection) = try await rig.start()
        #expect(await eventually { rig.control(2) == RestoreRig.gate }, "moved child first line marker")
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(await eventually { rig.changes.count == 3 }, "moved hook marker")
        #expect(rig.changes.map(\.reason) == ["voice", "moved", "resumed"])
        #expect(rig.changes.map(\.meetingID) == [meetingID, meetingID, meetingID])
        #expect(rig.changes[1].connection == stale && !rig.changes[1].on && !rig.changes[1].recording)
        #expect(rig.changes[2].connection == connection && rig.changes[2].recording)
        #expect(!rig.router.meetingMode(connection: stale) && rig.router.meetingMode(connection: connection))
        let moved = "mode=meeting from=\(stale) to=\(connection) meeting=\(meetingID)"
        #expect(await eventually { rig.details("ambient_mode_moved") == [moved] }, "move log marker")
        let restored = rig.details("meeting_restored").first ?? ""
        #expect(restored.hasPrefix("source=live from=\(stale) to=\(connection) meeting=\(meetingID)"))
        #expect(restored.contains("recording=true device_match=true"))
        // The stale device hears nothing more: no clip for the move, and its old child got no write.
        try await rig.clipAudio(on: first)
        try await barrier(on: first, step: "stale holder silent")
        try await rig.clipAudio(on: socket)
        try await barrier(on: socket, step: "one resumed clip only")
        #expect(rig.control(1) == RestoreRig.gate)
        // Its later teardown finds nothing to park.
        await rig.drop(first, stale)
        await rig.drainMeetingChanges()
        #expect(rig.parked == nil && rig.details("ambient_meeting_parked").isEmpty)
        await rig.finish()
    }

    @Test func aDifferentDeviceInheritsTheQuietGateUnrecorded() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, _) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        let (socket, connection) = try await rig.start(name: "other", kind: "pad")
        #expect(await eventually { rig.control(2) == RestoreRig.gate }, "different device gate marker")
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(await eventually { rig.changes.count == 3 }, "different device hook marker")
        #expect(rig.changes.last?.reason == "resumed_unrecorded" && rig.changes.last?.recording == false)
        #expect(rig.router.state.withLock { $0.meeting[connection]?.recording } == false)
        #expect(rig.details("meeting_restored").first?.contains("recording=false device_match=false") == true)
        await rig.finish()
    }

    /// Review round 2 (N5): a private start takes nothing, and ends every other holder's mode as a privacy entry does.
    @Test func aPrivateStartTakesNothingAndEndsTheHoldersMode() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, holder) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        let (socket, connection) = try await rig.connect()
        rig.router.state.withLock { $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        #expect(await eventually { rig.details("ambient_started").count == 2 }, "private start marker")
        #expect(!rig.router.meetingMode(connection: holder) && !rig.router.meetingMode(connection: connection))
        #expect(await eventually { rig.changes.count == 2 }, "private start ended holder marker")
        #expect(rig.changes.map(\.reason) == ["voice", "privacy"] && rig.details("ambient_mode_moved").isEmpty)
        await rig.finish()
        #expect(rig.control(2)?.contains("media") != true)
    }

    /// Guard 1: the old connection waking keeps no ungated window. It starts again, and the meeting moves back to it,
    /// same id; the holder it left ends as moved.
    @Test func theOldConnectionStartingAgainTakesTheMeetingBackGated() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, old) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        let (socket, newer) = try await rig.start()
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        try await recipientSocketSend(audio(UUID(), 0), on: first)
        #expect(await eventually { rig.router.activeConnection() == old }, "old connection restart marker")
        #expect(await eventually { rig.control(3) == RestoreRig.gate }, "old connection gated marker")
        #expect(try await rig.confirmation(on: first) == RestoreRig.resumed.text)
        #expect(await eventually { rig.changes.count == 5 }, "moved back hook marker")
        #expect(rig.changes.map(\.reason) == ["voice", "moved", "resumed", "moved", "resumed"])
        #expect(Set(rig.changes.map(\.meetingID)).count == 1)
        #expect(rig.router.meetingMode(connection: old) && !rig.router.meetingMode(connection: newer))
        await rig.finish()
    }

    /// Several holders: the latest-armed mode moves, and every other holder ends as moved.
    /// Review round 2 (N7): a holder that loses ends `superseded`, not `moved`: its meeting continues nowhere.
    @Test func theLatestArmedHolderWinsAndTheRestEndSuperseded() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, meeting) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        let (_, media) = try await rig.connect()
        rig.router.setMedia(true, connection: media, reason: "voice")
        let (_, connection) = try await rig.start()
        #expect(await eventually { rig.control(2) == RestoreRig.gate }, "latest holder gate marker")
        #expect(rig.router.mediaMode(connection: connection) && !rig.router.mediaMode(connection: media))
        #expect(!rig.router.meetingMode(connection: meeting) && !rig.router.meetingMode(connection: connection))
        #expect(await eventually { rig.changes.count == 2 }, "older holder superseded hook marker")
        #expect(rig.changes.map(\.reason) == ["voice", "superseded"])
        let meetingID = try #require(rig.changes.first?.meetingID)
        #expect(await eventually {
            rig.details("ambient_mode_ended") == ["reason=superseded mode=meeting from=\(meeting) meeting=\(meetingID)"]
        }, "superseded log marker")
        let moved = ["mode=media from=\(media) to=\(connection)"]
        #expect(await eventually { rig.details("ambient_mode_moved") == moved }, "media moved marker")
        let restored = "source=live from=\(media)"
        #expect(await eventually { rig.details("media_restored").first?.hasPrefix(restored) == true },
                "media moved log marker")
        await rig.finish()
    }
}
#endif
