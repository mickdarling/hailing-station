#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode restore (MM-E): a restored mode ends at its original instant, never after a fresh full timeout,
/// and a park past its expiry is discarded; one kind is parked at a time. Times are read off the rig's clock.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientModeRestoreExpiryTests {
    @Test func theOriginalExpiryIsKeptAndAnExpiredParkIsDiscarded() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        let expiry = try #require(rig.parked?.meeting?.expiresAt)
        rig.clock.advance(1_000)
        let (socket, connection) = try await rig.start()
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(rig.router.state.withLock { $0.meeting[connection]?.expiresAt } == expiry)
        await rig.drainMeetingChanges()
        let logged = try #require(RestoreRig.remaining(in: rig.details("meeting_restored").first))
        #expect(abs(logged - Int(expiry.timeIntervalSince(rig.clock.now()))) <= 2)
        // A second drop parks the same instant: drops never extend it.
        await rig.drop(socket, connection)
        #expect(rig.parked?.meeting?.expiresAt == expiry)
        rig.clock.advance(10_000)
        let (_, late) = try await rig.start()
        #expect(!rig.router.meetingMode(connection: late) && rig.parked == nil)
        #expect(await eventually {
            rig.details("ambient_park_discarded") == ["reason=expired mode=meeting"]
        }, "expired park log marker")
        await rig.finish()
        #expect(rig.control(3)?.contains("media") == false)
    }

    /// Three seconds left of a sixty-second meeting: a fresh full timeout would not end it within six.
    @Test func theRestoredMeetingEndsAtTheOriginalInstant() async throws {
        let rig = try await RestoreRig(timeout: 60)
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        let expiry = try #require(rig.parked?.meeting?.expiresAt)
        rig.clock.advance(expiry.timeIntervalSince(rig.clock.now()) - 3)
        let (socket, connection) = try await rig.start()
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(try await rig.confirmation(on: socket, within: .seconds(6)) == MeetingRig.ended.text)
        #expect(rig.clock.now() >= expiry.addingTimeInterval(-0.5))
        #expect(await eventually { rig.changes.count == 4 }, "restored timeout hook marker")
        #expect(rig.changes.last?.reason == "timeout" && rig.changes.last?.connection == connection)
        #expect(await eventually { rig.control(2) == RestoreRig.gate + "{\"media\":false}\n" }, "restored end marker")
        await rig.finish()
    }

    @Test func theRestoredMediaModeEndsAtTheOriginalInstant() async throws {
        let rig = try await RestoreRig(phrase: "media mode", mediaTimeout: 60)
        defer { rig.close() }
        let (first, dropped) = try await rig.start()
        #expect(await eventually { rig.router.mediaMode(connection: dropped) }, "media on marker")
        await rig.drop(first, dropped)
        let expiry = try #require(rig.parked?.media?.expiresAt)
        rig.clock.advance(expiry.timeIntervalSince(rig.clock.now()) - 2)
        let (_, connection) = try await rig.start()
        #expect(rig.router.mediaMode(connection: connection))
        let deadline = ContinuousClock.now + .seconds(5)
        while rig.router.mediaMode(connection: connection), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(!rig.router.mediaMode(connection: connection), "restored media outlived its original expiry")
        #expect(rig.clock.now() >= expiry.addingTimeInterval(-0.5))
        await rig.finish()
    }

    @Test func anExpiredMediaParkIsDiscarded() async throws {
        let rig = try await RestoreRig(phrase: "media mode")
        defer { rig.close() }
        let (first, dropped) = try await rig.start()
        #expect(await eventually { rig.router.mediaMode(connection: dropped) }, "media on marker")
        await rig.drop(first, dropped)
        rig.clock.advance(AmbientRightyoRouter.defaultMediaTimeout + 60)
        let (_, connection) = try await rig.start()
        #expect(!rig.router.mediaMode(connection: connection) && rig.parked == nil)
        #expect(await eventually { rig.details("ambient_park_discarded") == ["reason=expired mode=media"] },
                "expired media log marker")
        await rig.finish()
        #expect(rig.control(2)?.contains("media") == false)
    }

    /// A meeting on one device, then media mode on another: both drop, and only the latest command is parked.
    @Test func onlyTheLatestKindIsParkedAndRestored() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, meeting) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        let (second, media) = try await rig.connect()
        rig.router.setMedia(true, connection: media, reason: "voice")
        await rig.drop(first, meeting)
        #expect(rig.parked?.meeting != nil)
        second.cancel(with: .goingAway, reason: nil)
        #expect(await eventually { rig.parked?.media != nil }, "later media park marker")
        #expect(rig.parked?.meeting == nil)
        let (_, connection) = try await rig.start()
        #expect(rig.router.mediaMode(connection: connection) && !rig.router.meetingMode(connection: connection))
        #expect(await eventually { rig.details("ambient_park_discarded") == ["reason=superseded mode=meeting"] },
                "superseded meeting park marker")
        await rig.finish()
    }
}
#endif
