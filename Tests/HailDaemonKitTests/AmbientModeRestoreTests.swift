#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode restore (MM-E): a meeting or media mode a dropped connection left on comes back, quieter only, on
/// the next ambient start of any connection, before its original expiry. Synthetic devices only; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientModeRestoreTests {
    /// A meeting on, then dropped and parked; returns the dropped device's meeting id.
    static func meetingDropped(_ rig: RestoreRig, kind: String? = "phone") async throws -> UUID {
        let (socket, connection) = try await rig.start(kind: kind)
        #expect(try await rig.confirmation(on: socket) == MeetingRig.on.text)
        await rig.drop(socket, connection)
        #expect(rig.parked?.meeting != nil)
        #expect(await eventually { rig.details("ambient_meeting_parked").count == 1 }, "meeting parked log marker")
        let first = try #require(rig.changes.first)
        #expect(first.on && first.recording && first.reason == "voice")
        return first.meetingID
    }

    @Test func theSameDeviceGetsItsMeetingBackRecorded() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let meetingID = try await Self.meetingDropped(rig)
        let (socket, connection) = try await rig.start()
        // The gate is the restored child's very first control line: it never ran ungated.
        #expect(await eventually { rig.control(2) == RestoreRig.gate }, "restored child first line marker")
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(await eventually { rig.changes.count == 3 }, "resumed hook marker")
        #expect(rig.changes.map(\.reason) == ["voice", "connection", "resumed"])
        let resumed = try #require(rig.changes.last)
        #expect(resumed.on && resumed.recording && resumed.connection == connection && resumed.meetingID == meetingID)
        #expect(rig.router.state.withLock { $0.meeting[connection]?.recording } == true && rig.parked == nil)
        let detail = rig.details("meeting_restored").first ?? ""
        #expect(detail.hasPrefix("source=park from=") && detail.contains("to=\(connection) meeting=\(meetingID)"))
        #expect(detail.contains("recording=true device_match=true"))
        await rig.finish()
        #expect(rig.control(2) == RestoreRig.gate)
    }

    /// The dropped device's class, then the new device's claims.
    struct Claims: Sendable {
        let dropped: String?
        let name: String
        let kind: String?
    }

    /// A different name, a different class, or a class unknown on either side: the gate, but no recording.
    @Test(arguments: [Claims(dropped: "phone", name: "other", kind: "phone"),
                      Claims(dropped: "phone", name: "test", kind: "pad"),
                      Claims(dropped: "phone", name: "test", kind: nil), Claims(dropped: nil, name: "test", kind: nil)])
    func anotherDeviceGetsTheGateButNoRecording(_ claims: Claims) async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let meetingID = try await Self.meetingDropped(rig, kind: claims.dropped)
        let (socket, connection) = try await rig.start(name: claims.name, kind: claims.kind)
        #expect(await eventually { rig.control(2) == RestoreRig.gate }, "unrecorded child first line marker")
        // Mick must still know the gate is up.
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(await eventually { rig.changes.count == 3 }, "unrecorded hook marker")
        let resumed = try #require(rig.changes.last)
        #expect(resumed.reason == "resumed_unrecorded" && !resumed.recording && resumed.meetingID == meetingID)
        #expect(rig.router.state.withLock { $0.meeting[connection]?.recording } == false)
        #expect(rig.details("meeting_restored").first?.contains("recording=false device_match=false") == true)
        // Only whether the claims matched is logged, never a device name.
        #expect(!rig.details("meeting_restored").joined().contains("other"))
        await rig.finish()
    }

    /// The claims rule on its own: both known, same name, same known class.
    @Test func onlyTheSameKnownClaimsMatch() {
        let phone = AmbientPeerDevice(name: "test", deviceClass: "phone")
        #expect(AmbientPeerDevice.matches(phone, phone))
        #expect(!AmbientPeerDevice.matches(nil, nil) && !AmbientPeerDevice.matches(phone, nil))
        #expect(!AmbientPeerDevice.matches(nil, phone))
        let unknown = AmbientPeerDevice(name: "test", deviceClass: nil)
        #expect(!AmbientPeerDevice.matches(unknown, unknown))
        #expect(!AmbientPeerDevice.matches(phone, AmbientPeerDevice(name: "test", deviceClass: "pad")))
        #expect(!AmbientPeerDevice.matches(phone, AmbientPeerDevice(name: "other", deviceClass: "phone")))
    }

    /// A teardown without the dropped device's claims (`stop(connection:)`) never lets the restore record.
    @Test func aParkWithoutClaimsNeverRecords() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, dropped) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        rig.router.stop(connection: dropped)
        #expect(rig.parked?.meeting != nil && rig.parked?.device == nil)
        let (socket, _) = try await rig.start()
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(await eventually { rig.changes.count == 3 }, "claimless hook marker")
        #expect(rig.changes.last?.reason == "resumed_unrecorded" && rig.changes.last?.recording == false)
        await rig.finish()
    }

    @Test func mediaModeComesBackSilently() async throws {
        let rig = try await RestoreRig(phrase: "media mode")
        defer { rig.close() }
        let (first, dropped) = try await rig.start()
        #expect(await eventually { rig.router.mediaMode(connection: dropped) }, "media on marker")
        await rig.drop(first, dropped)
        #expect(rig.parked?.media != nil && rig.parked?.meeting == nil)
        #expect(rig.details("ambient_media_parked").count == 1)
        let (socket, connection) = try await rig.start()
        #expect(await eventually { rig.control(2) == RestoreRig.gate }, "restored media child marker")
        #expect(await eventually { rig.details("media_restored").count == 1 }, "media restored log marker")
        #expect(rig.details("media_restored").first?.contains("device_match=true") == true)
        #expect(rig.router.mediaMode(connection: connection) && rig.parked == nil && rig.changes.isEmpty)
        // No clip: a stray frame fails the barrier.
        try await barrier(on: socket, step: "silent media restore")
        await rig.finish()
    }

    @Test func onlyTheFirstStartTakesThePark() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await Self.meetingDropped(rig)
        let (socket, restored) = try await rig.start()
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(rig.parked == nil)
        // A later start finds no park; it takes the meeting from its live holder instead, never a second copy.
        let (_, second) = try await rig.start()
        #expect(!rig.router.meetingMode(connection: restored) && rig.router.meetingMode(connection: second))
        #expect(await eventually { rig.details("meeting_restored").count == 2 }, "second restore log marker")
        #expect(rig.details("meeting_restored").map { $0.hasPrefix("source=park") } == [true, false])
        await rig.finish()
    }

    @Test func aFreshRouterRestoresNothing() async throws {
        let before = try await RestoreRig()
        defer { before.close() }
        _ = try await Self.meetingDropped(before)
        await before.finish()
        // haild restarted: the park lived in the old router's memory only.
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        #expect(rig.parked == nil)
        let (_, connection) = try await rig.start()
        #expect(!rig.router.meetingMode(connection: connection) && rig.details("meeting_restored").isEmpty)
        await rig.finish()
        #expect(rig.control(1)?.contains("media") == false)
    }

    @Test func aReloadOfTheRestoredStreamKeepsTheGate() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await Self.meetingDropped(rig)
        let (socket, _) = try await rig.start()
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        let router = rig.router
        #expect(await eventually { router.status().liveChildren == 1 }, "dropped child reaped marker")
        await bounded("restored child reload") { #expect(await router.reload() == .reloaded) }
        #expect(await eventually { rig.control(3) == RestoreRig.gate }, "reloaded restored child marker")
        #expect(rig.changes.count == 3)
        await rig.finish()
    }

    /// Finding 2: a start whose connection was torn down (or superseded) before its run registered leaves the park.
    /// The real window is a process spawn on the worker path, so the guard is driven directly, under the lock.
    @Test func aStartNoLongerCurrentLeavesThePark() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, dropped) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        let (router, gone) = (rig.router, UUID())
        let pipeline = try #require(router.activePipeline)
        await rig.drop(first, dropped)
        router.state.withLock { router.carryModes(to: gone, stream: UUID(), pipeline: pipeline, in: &$0) }
        #expect(rig.parked?.meeting != nil && !router.meetingMode(connection: gone))
        router.state.withLock { $0.latest[gone] = UUID() }
        router.state.withLock { router.carryModes(to: gone, stream: UUID(), pipeline: pipeline, in: &$0) }
        #expect(rig.parked?.meeting != nil && !router.meetingMode(connection: gone))
        router.state.withLock { $0.latest[gone] = nil }
        await rig.finish()
    }
}
#endif
