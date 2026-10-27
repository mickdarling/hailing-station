#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// An owner's off on a restored connection B (#941, Jarvis's ruling at #945 round 2) ends privacy only on B's recorded
/// restore source A, and only if A is the same class of device, still holds the arming B was restored from, and does
/// not answer a WebSocket ping. Every device here sends the app's own claims (Hello name "hail terminal"); the app's
/// `URLSessionWebSocketTask` answers pings itself, and a `SilentPeer` never does. Synthetic only; waits bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyOffScopeTests {
    struct Scene {
        let rig: RestoreRig
        let source: UUID
        let restored: UUID
    }

    /// Source A (a silent peer, or one that answers pings) is private by the owner's voice and still open; B, of class
    /// `kind`, is restored private from it. Returns before any off.
    static func restoredFrom(silent: Bool, sourceKind: String? = "phone", kind: String? = "phone",
                             privacy: PrivacyOffSettings? = nil) async throws -> (Scene, SilentPeer?) {
        // A silent source's probe waits out the timeout, so it is shortened; a live one's pong ends it at once.
        let rig = try await RestoreRig(phrase: "stop recording", privacy: privacy ?? (silent ? .silent : .init()))
        let (peer, source) = try await Self.source(on: rig, silent: silent, kind: sourceKind)
        let router = rig.router
        #expect(await eventually { router.activeConnection() == source }, "source start marker")
        try #require(await eventually { router.duckMode(connection: source) }, "source holds privacy")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty }, "privacy entry settled")
        let (_, restored) = try await rig.start(name: RestoreRig.appName, kind: kind)
        #expect(router.duckMode(connection: restored))
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        return (Scene(rig: rig, source: source, restored: restored), peer)
    }

    /// The source device: a silent peer, or one with the app's own transport, which answers pings. Like the app
    /// (`HostConnection+Lifecycle`'s receive loop), the live one always has a receive pending, so its
    /// `URLSessionWebSocketTask` reads, and answers, a ping as it arrives.
    static func source(on rig: RestoreRig, silent: Bool, kind: String?) async throws -> (SilentPeer?, UUID) {
        guard silent else {
            let (socket, connection) = try await rig.start(name: RestoreRig.appName, kind: kind)
            Task { while (try? await socket.receive()) != nil {} }
            return (nil, connection)
        }
        let (peer, connection) = try await rig.connectSilent(kind: kind)
        try await peer.send(audio(UUID(), 0))
        return (peer, connection)
    }

    /// The owner's off on the restored connection, then its scope's log line.
    static func off(_ scene: Scene) async -> String? {
        _ = scene.rig.router.setDuck(false, connection: scene.restored, reason: "voice")
        #expect(!scene.rig.router.duckMode(connection: scene.restored))
        #expect(await eventually { !scene.rig.details("ambient_privacy_off_scoped").isEmpty }, "off scope marker")
        return scene.rig.details("ambient_privacy_off_scoped").first
    }

    /// (i) A same-class source that does not answer a ping is stale: it stops counting as a source, so a fresh stream on
    /// another connection starts public, while the source itself stays private (ducked, its replies held). Its
    /// teardown then parks nothing, and the next stream is public too.
    @Test func aSameClassStaleSourceIsCleared() async throws {
        let (scene, peer) = try await Self.restoredFrom(silent: true)
        let (rig, router) = (scene.rig, scene.rig.router)
        defer { peer?.cancel(); rig.close() }
        #expect(await Self.off(scene) == "cleared=1 kept=0 \(scene.source)=stale")
        #expect(router.duckMode(connection: scene.source))
        #expect(await rig.env.listener.replyHold.holds(scene.source))
        let (_, fresh) = try await rig.start(name: RestoreRig.appName)
        #expect(!router.duckMode(connection: fresh) && router.duckMode(connection: scene.source))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 3))
        peer?.cancel()
        // Its teardown drops its privacy ledger: the marker that `stop(connection:)` has run.
        #expect(await eventually { router.state.withLock { $0.privacy[scene.source] == nil } },
                "stale source teardown marker")
        await rig.drainMeetingChanges()
        #expect(router.state.withLock { $0.parkedPrivacy } == nil && rig.details("ambient_privacy_parked").isEmpty)
        let (_, next) = try await rig.start(name: RestoreRig.appName)
        #expect(!router.duckMode(connection: next))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 4))
        await rig.finish()
    }

    /// (ii) A same-class source that answers a ping is live (two iPhones): it keeps its privacy.
    @Test func aSameClassLiveSourceKeepsItsPrivacy() async throws {
        let (scene, _) = try await Self.restoredFrom(silent: false)
        defer { scene.rig.close() }
        #expect(await Self.off(scene) == "cleared=0 kept=1 \(scene.source)=live")
        #expect(scene.rig.router.duckMode(connection: scene.source))
        await scene.rig.finish()
    }

    /// (iii) A same-class private connection that is not the off's restore source keeps its privacy, even silent.
    @Test func aSameClassConnectionThatIsNotTheSourceKeepsItsPrivacy() async throws {
        let (scene, peer) = try await Self.restoredFrom(silent: true)
        let (rig, router) = (scene.rig, scene.rig.router)
        defer { peer?.cancel(); rig.close() }
        // A third connection is restored private from A or B, so it holds privacy but is not B's source.
        let (other, otherConnection) = try await rig.connectSilent()
        defer { other.cancel() }
        try await other.send(audio(UUID(), 0))
        #expect(await eventually { router.duckMode(connection: otherConnection) }, "third connection private")
        let line = await Self.off(scene)
        #expect(line?.contains("\(otherConnection)=not_source") == true)
        #expect(line?.contains("\(scene.source)=stale") == true)
        #expect(router.duckMode(connection: otherConnection))
        await rig.finish()
    }

    /// (iii) A connection restored from the park records no source, so its off ends no other connection's privacy:
    /// here one restored from it later, silent and of the same class.
    @Test func aRestoreFromTheParkRecordsNoSource() async throws {
        let rig = try await RestoreRig(phrase: "stop recording", privacy: .silent)
        defer { rig.close() }
        let router = rig.router
        let (first, dropped) = try await rig.connectSilent()
        try await first.send(audio(UUID(), 0))
        try #require(await eventually { router.duckMode(connection: dropped) }, "first connection holds privacy")
        first.cancel()
        #expect(await eventually { router.state.withLock { $0.parkedPrivacy?.connection } == dropped }, "parked")
        let (_, restored) = try await rig.start(name: RestoreRig.appName)
        let (later, laterConnection) = try await rig.connectSilent()
        defer { later.cancel() }
        try await later.send(audio(UUID(), 0))
        #expect(await eventually { router.duckMode(connection: laterConnection) }, "later connection private")
        let line = await Self.off(Scene(rig: rig, source: dropped, restored: restored))
        #expect(line == "cleared=0 kept=1 \(laterConnection)=not_source")
        #expect(router.duckMode(connection: laterConnection))
        await rig.finish()
    }

    /// (iv) A source of another class, or of unknown class, keeps its privacy, even silent: also when both are unknown,
    /// since an unknown class never matches (MM-E), even its like.
    @Test(arguments: [("pad", "phone"), (nil, "phone"), (nil, nil)] as [(String?, String?)])
    func anotherOrUnknownClassKeepsItsPrivacy(sourceKind: String?, kind: String?) async throws {
        let (scene, peer) = try await Self.restoredFrom(silent: true, sourceKind: sourceKind, kind: kind)
        defer { peer?.cancel(); scene.rig.close() }
        #expect(await Self.off(scene) == "cleared=0 kept=1 \(scene.source)=class")
        #expect(scene.rig.router.duckMode(connection: scene.source))
        await scene.rig.finish()
    }

    /// A stale source re-armed after the off but before its scope decides keeps the new arming (review round 2 P3-1).
    @Test func aSourceReArmedBeforeTheDecisionKeepsItsPrivacy() async throws {
        let box = RouterBox(), source = SourceBox()
        let settings = PrivacyOffSettings(probeTimeout: .milliseconds(500), offScoping: { _ in
            guard let connection = source.value.withLock({ $0 }) else { return }
            box.value.withLock { $0 }?.state.withLock {
                $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil)
            }
        })
        let (scene, peer) = try await Self.restoredFrom(silent: true, privacy: settings)
        defer { peer?.cancel(); scene.rig.close() }
        box.value.withLock { $0 = scene.rig.router }
        source.value.withLock { $0 = scene.source }
        #expect(await Self.off(scene) == "cleared=0 kept=1 \(scene.source)=armed")
        #expect(scene.rig.router.duckMode(connection: scene.source))
        await scene.rig.finish()
    }
}

/// The connection a hook set before it existed reaches.
final class SourceBox: Sendable {
    let value = Mutex<UUID?>(nil)
}
#endif
