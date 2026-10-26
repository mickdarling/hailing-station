#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// An owner's off on a reconnected connection while the old one is still open and private (#941 review round 1, P1;
/// Jarvis's ruling): the off clears the park and ends privacy on the same device's other connections (stale holders),
/// matched by Hello name and known class as MM-E matches; another device, or claims that cannot match, keeps its
/// privacy. Synthetic devices only; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyOffScopeTests {
    struct Scene {
        let rig: RestoreRig
        let old: URLSessionWebSocketTask
        let stale: UUID
    }

    /// The old connection (`kind`) is private and open; a reconnect with these claims is restored private from it,
    /// then the owner turns privacy off there by voice. Returns once the off's scope is logged.
    static func offAfterReconnect(staleKind: String? = "phone", name: String = "test",
                                  kind: String? = "phone") async throws -> Scene {
        let (rig, (old, stale)) = try await AmbientPrivacyParkLiveTests.privateStillOpen(kind: staleKind)
        let (_, fresh) = try await rig.start(name: name, kind: kind)
        let router = rig.router
        #expect(router.duckMode(connection: fresh))
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        #expect(router.setDuck(false, connection: fresh, reason: "voice") == 1)
        #expect(await eventually { !rig.details("ambient_privacy_off_scoped").isEmpty }, "off scope log marker")
        return Scene(rig: rig, old: old, stale: stale)
    }

    /// The same device: its stale connection's privacy ends too, so its teardown parks nothing and the next stream
    /// starts public.
    @Test func theSameDevicesStaleConnectionEndsWithTheOff() async throws {
        let scene = try await Self.offAfterReconnect()
        let (rig, router) = (scene.rig, scene.rig.router)
        defer { rig.close() }
        #expect(rig.details("ambient_privacy_off_scoped") == ["cleared=1 kept=0 to=\(scene.stale.uuidString)"])
        #expect(!router.duckMode(connection: scene.stale))
        #expect(await eventually { await !rig.env.listener.replyHold.holds(scene.stale) }, "stale hold released")
        await rig.drop(scene.old, scene.stale)
        await rig.drainMeetingChanges()
        #expect(router.state.withLock { $0.parkedPrivacy } == nil && rig.details("ambient_privacy_parked").isEmpty)
        let (_, next) = try await rig.start()
        #expect(!router.duckMode(connection: next))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 3))
        await rig.finish()
    }

    /// Another device keeps its privacy: privacy always wins, and its own teardown parks it again.
    @Test func anotherDeviceKeepsItsPrivacy() async throws {
        let scene = try await Self.offAfterReconnect(name: "other", kind: "watch")
        let (rig, router) = (scene.rig, scene.rig.router)
        defer { rig.close() }
        #expect(rig.details("ambient_privacy_off_scoped") == ["cleared=0 kept=1"])
        #expect(router.duckMode(connection: scene.stale))
        await rig.drop(scene.old, scene.stale)
        #expect(router.state.withLock { $0.parkedPrivacy?.connection } == scene.stale)
        let (_, next) = try await rig.start()
        #expect(router.duckMode(connection: next))
        await rig.finish()
    }

    /// Claims that cannot match (no device class, as MM-E's match needs one) fail closed: kept private, even with the
    /// same name.
    @Test func unknownClaimsKeepTheirPrivacy() async throws {
        let scene = try await Self.offAfterReconnect(staleKind: nil, kind: nil)
        let (rig, router) = (scene.rig, scene.rig.router)
        defer { rig.close() }
        #expect(rig.details("ambient_privacy_off_scoped") == ["cleared=0 kept=1"])
        #expect(router.duckMode(connection: scene.stale))
        await rig.finish()
    }
}
#endif
