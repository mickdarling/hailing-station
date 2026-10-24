#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode restore (MM-E): privacy always wins over a parked mode, and the owner's own latest word clears
/// it. Synthetic devices only; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientModeRestorePrivacyTests {
    /// The park waits while another connection's child listens; that child's privacy entry discards it. The meeting
    /// is set host-side on a connection with no stream, so the listening child predates it (as no voice entry can).
    @Test func aPrivacyEntryOnAnyConnectionDiscardsThePark() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (_, listening) = try await rig.start()
        let (held, holder) = try await rig.connect()
        #expect(rig.router.setMeeting(on: true, connection: holder, reason: "voice") == 0)
        held.cancel(with: .goingAway, reason: nil)
        #expect(await eventually { rig.parked?.meeting != nil }, "meeting parked marker")
        let router = rig.router
        #expect(await eventually { router.activePipeline?.childStarted == true }, "listening child started marker")
        #expect(router.setDuck(true, connection: listening, reason: "voice") == 1)
        #expect(rig.parked == nil)
        #expect(await eventually {
            rig.details("ambient_park_discarded") == ["reason=privacy mode=meeting"]
        }, "privacy discard log marker")
        await rig.finish()
    }

    /// Part 10: a restored meeting that then goes private ends as `privacy`, and is never parked again.
    @Test func aRestoredMeetingThenPrivacyEndsAndALaterDropParksNothing() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        let (socket, connection) = try await rig.start()
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        let router = rig.router
        #expect(await eventually { router.activePipeline?.childStarted == true }, "restored child started marker")
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        #expect(!router.meetingMode(connection: connection))
        #expect(await eventually { rig.changes.count == 4 }, "restored privacy hook marker")
        #expect(rig.changes.map(\.reason) == ["voice", "connection", "resumed", "privacy"])
        await rig.drop(socket, connection)
        #expect(rig.parked == nil && rig.details("ambient_meeting_parked").count == 1)
        #expect(rig.changes.count == 4)
        await rig.finish()
    }

    /// A private connection never has a meeting (privacy ends it), so the guard is shown on forced state.
    @Test func aPrivateTeardownParksNothing() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (socket, connection) = try await rig.start()
        #expect(try await rig.confirmation(on: socket) == MeetingRig.on.text)
        rig.router.state.withLock { $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
        await rig.drop(socket, connection)
        #expect(rig.parked == nil && !rig.router.meetingMode(connection: connection))
        #expect(rig.details("ambient_meeting_parked").isEmpty)
        await rig.finish()
    }

    @Test func aStartThatIsPrivateDiscardsThePark() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        let (socket, connection) = try await rig.connect()
        rig.router.state.withLock { $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        #expect(await eventually { rig.parked == nil }, "private start consumed the park marker")
        #expect(!rig.router.meetingMode(connection: connection) && rig.details("meeting_restored").isEmpty)
        #expect(await eventually {
            rig.details("ambient_park_discarded") == ["reason=privacy mode=meeting"]
        }, "private start discard log marker")
        await rig.finish()
        #expect(rig.control(2)?.contains("media") != true)
    }

    @Test func theOwnersOffOnAnyConnectionClearsAParkedMeeting() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        #expect(rig.router.setMeeting(on: false, connection: UUID(), reason: "voice") == 0)
        #expect(rig.parked == nil)
        let (_, connection) = try await rig.start()
        #expect(!rig.router.meetingMode(connection: connection) && rig.details("meeting_restored").isEmpty)
        #expect(await eventually { rig.details("ambient_park_discarded") == ["reason=off mode=meeting"] },
                "meeting off discard log marker")
        await rig.finish()
        #expect(rig.control(2)?.contains("media") == false)
    }

    @Test func theOwnersMediaOffClearsAParkedMediaMode() async throws {
        let rig = try await RestoreRig(phrase: "media mode")
        defer { rig.close() }
        let (socket, connection) = try await rig.start()
        #expect(await eventually { rig.router.mediaMode(connection: connection) }, "media on marker")
        await rig.drop(socket, connection)
        #expect(rig.parked?.media != nil)
        #expect(rig.router.setMedia(false, connection: UUID(), reason: "voice") == 0)
        #expect(rig.parked == nil)
        #expect(await eventually { rig.details("ambient_park_discarded") == ["reason=off mode=media"] },
                "media off discard log marker")
        await rig.finish()
    }

    @Test func theOtherModesEntrySupersedesThePark() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        let elsewhere = UUID()
        rig.router.setMedia(true, connection: elsewhere, reason: "voice")
        #expect(rig.parked == nil)
        #expect(await eventually { rig.details("ambient_park_discarded") == ["reason=superseded mode=meeting"] },
                "superseded discard log marker")
        rig.router.setMedia(false, connection: elsewhere, reason: "timeout")
        await rig.finish()
    }

    @Test func aMeetingEntrySupersedesAParkedMediaMode() async throws {
        let rig = try await RestoreRig(phrase: "media mode")
        defer { rig.close() }
        let (socket, connection) = try await rig.start()
        #expect(await eventually { rig.router.mediaMode(connection: connection) }, "media on marker")
        await rig.drop(socket, connection)
        #expect(rig.parked?.media != nil)
        let elsewhere = UUID()
        rig.router.setMeeting(on: true, connection: elsewhere, reason: "voice")
        #expect(rig.parked == nil)
        #expect(await eventually { rig.details("ambient_park_discarded") == ["reason=superseded mode=media"] },
                "superseded media park marker")
        rig.router.setMeeting(on: false, connection: elsewhere, reason: "timeout")
        await rig.finish()
    }
}
#endif
