#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #1041 option (b): equal Hello claims never authorize withdrawing another connection's privacy contribution.
/// Synthetic terminals, loopback transport and fake RightyO; no physical-device or microphone proof.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyOffIsolationTests {
    @Test func equalHelloClaimsDoNotWithdrawAnotherSource() async throws {
        let (scene, silent) = try await AmbientPrivacyOffScopeTests.restoredFrom(silent: true)
        let peer = try #require(silent), rig = scene.rig
        defer { peer.cancel(); rig.close() }
        let here = await rig.env.listener.ambientPeerDevice(connection: scene.restored)
        let there = await rig.env.listener.ambientPeerDevice(connection: scene.source)
        #expect(AmbientPeerDevice.matches(here, there), "both terminals make equal name and known-class claims")
        _ = try await AmbientPrivacyFalseStaleTests.framesUntilPong(peer)
        try await AmbientPrivacyOffScopeTests.off(scene)
        #expect(rig.router.duckMode(connection: scene.source))
        #expect(await rig.env.listener.replyHold.holds(scene.source))
        #expect(try await AmbientPrivacyFalseStaleTests.framesUntilPong(peer).isEmpty, "no off sent to the holder")
        try await AmbientPrivacyFalseStaleTests.expectPrivateFreshStream(rig, spawn: 3)
    }

    @Test func lateSourceTeardownReparksAfterOwnerOff() async throws {
        let (scene, silent) = try await AmbientPrivacyOffScopeTests.restoredFrom(silent: true)
        let peer = try #require(silent), rig = scene.rig, router = scene.rig.router
        defer { peer.cancel(); rig.close() }
        try await AmbientPrivacyOffScopeTests.off(scene)
        #expect(router.state.withLock { $0.parks.isEmpty })
        peer.cancel()
        try #require(await eventually { router.state.withLock { $0.parks[scene.source] != nil } }, "late park")
        #expect(await !rig.env.listener.replyHold.holds(scene.source), "teardown releases its connection hold")
        #expect(router.state.withLock { $0.parks.count == 1 && !$0.parkOverflow })
        try await AmbientPrivacyFalseStaleTests.expectPrivateFreshStream(rig, spawn: 3)
    }

    @Test func ownerOffAfterLastHolderTeardownClearsPrivacy() async throws {
        let (scene, silent) = try await AmbientPrivacyOffScopeTests.restoredFrom(silent: true)
        let peer = try #require(silent), rig = scene.rig, router = scene.rig.router
        defer { peer.cancel(); rig.close() }
        try await AmbientPrivacyOffScopeTests.off(scene)
        peer.cancel()
        try #require(await eventually { router.state.withLock { $0.parks[scene.source] != nil } }, "last holder parked")
        let parked = UUID()
        router.state.withLock {
            $0.parks[parked] = ParkedPrivacy(connection: parked, device: nil, parkedAt: rig.clock.now())
            $0.parkOverflow = true
        }
        let capable = try await SnapshotPeer(rig)
        defer { capable.close() }
        try await AmbientPrivacySwitchTests.send(false, on: capable.socket)
        let reply = try await AmbientPrivacySwitchTests.untilPong(capable.socket, step: "second deliberate off")
        #expect(reply == [.control(.duckMode(on: false, reason: "device"))])
        #expect(router.state.withLock { $0.duck.isEmpty && $0.parks.isEmpty && !$0.parkOverflow })
        #expect(await !rig.env.listener.replyHold.holds(capable.connection))
        let (_, fresh) = try await rig.start(name: RestoreRig.appName)
        #expect(!router.duckMode(connection: fresh))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 3))
        await rig.finish()
    }
}
#endif
