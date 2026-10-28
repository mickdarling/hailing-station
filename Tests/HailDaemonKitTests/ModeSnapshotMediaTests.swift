#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ModeSnapshotMediaTests {
    @Test(arguments: [false, true])
    func mediaSnapshotIncludesOriginalExpiryWithoutConsuming(parked: Bool) async throws {
        let rig = try await RestoreRig(phrase: "media mode")
        defer { rig.close() }
        let (socket, source) = try await rig.start()
        #expect(await eventually { rig.router.mediaMode(connection: source) }, "source holds media")
        let expiry = try #require(rig.router.state.withLock { $0.media[source]?.expiresAt })
        if parked { await rig.drop(socket, source) }
        let peer = try await SnapshotPeer(rig)
        defer { peer.close() }
        #expect(peer.modes == [.control(.duckMode(on: false)),
                               .control(.mediaMode(on: true, expires: Int64(expiry.timeIntervalSince1970 * 1_000)))])
        #expect(!rig.router.mediaMode(connection: peer.connection), "snapshot is read-only")
        #expect(parked ? rig.parked?.media != nil : rig.router.mediaMode(connection: source))
        await rig.finish()
    }

    @Test func expiryAndPrivacyWinAndMeetingHasNoDeviceFrame() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let source = UUID(), now = rig.clock.now()
        rig.router.state.withLock {
            $0.parked = ParkedModes(media: ParkedMedia(expiresAt: now.addingTimeInterval(-1),
                                                     connection: source, armed: 1), parkedAt: now)
        }
        let expired = try await SnapshotPeer(rig)
        defer { expired.close() }
        #expect(expired.modes == [.control(.duckMode(on: false)), .control(.mediaMode(on: false))])
        rig.router.state.withLock {
            $0.parked = ParkedModes(meeting: ParkedMeeting(profile: .meeting, meetingID: UUID(), started: now,
                expiresAt: now.addingTimeInterval(600), connection: source, recording: false, armed: 3), parkedAt: now)
            $0.media[source] = AmbientMediaTimer(token: UUID(), timer: Task {},
                                               expiresAt: now.addingTimeInterval(600), armed: 2)
        }
        let meeting = try await SnapshotPeer(rig)
        defer { meeting.close() }
        #expect(meeting.modes == [.control(.duckMode(on: false)), .control(.mediaMode(on: false))])
        rig.router.state.withLock { $0.parked = nil; $0.parkOverflow = true }
        let privatePeer = try await SnapshotPeer(rig)
        defer { privatePeer.close() }
        #expect(privatePeer.modes == [.control(.duckMode(on: true)), .control(.mediaMode(on: false))])
        await rig.finish()
    }
}
#endif
