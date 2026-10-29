#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #1041: an owner's off leaves every other holder contributing, whatever its claims or responsiveness.
/// Real loopback listener and fake RightyO; synthetic only, every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyOffScopeTests {
    struct Scene {
        let rig: RestoreRig
        let source: UUID
        let restored: UUID
        let socket: URLSessionWebSocketTask
    }

    /// A private holder stays connected while B starts private. A silent holder never answers WebSocket pings.
    static func restoredFrom(silent: Bool, sourceKind: String? = "phone",
                             kind: String? = "phone") async throws -> (Scene, SilentPeer?) {
        let rig = try await RestoreRig(phrase: "stop recording")
        let (peer, source) = try await Self.source(on: rig, silent: silent, kind: sourceKind)
        let router = rig.router
        try #require(await eventually { router.duckMode(connection: source) }, "source holds privacy")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty }, "privacy entry settled")
        let (socket, restored) = try await rig.start(name: RestoreRig.appName, kind: kind,
                                                   capabilities: [DuckMode.capability])
        #expect(router.duckMode(connection: restored))
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        #expect(await eventually { !rig.details("ambient_privacy_restored").isEmpty }, "restore notice queued")
        return (Scene(rig: rig, source: source, restored: restored, socket: socket), peer)
    }

    static func source(on rig: RestoreRig, silent: Bool, kind: String?) async throws -> (SilentPeer?, UUID) {
        guard silent else {
            let (socket, connection) = try await rig.start(name: RestoreRig.appName, kind: kind)
            Task { while (try? await socket.receive()) != nil {} }
            return (nil, connection)
        }
        let (peer, connection) = try await rig.connectSilent(kind: kind, capabilities: [DuckMode.capability])
        try await peer.send(audio(UUID(), 0))
        return (peer, connection)
    }

    /// Drive the real device switch, waiting for the current connection's off notice, never a probe/log verdict.
    static func off(_ scene: Scene) async throws {
        try await AmbientPrivacySwitchTests.send(false, on: scene.socket)
        try await AmbientPrivacyPreArmTests.until(.duckMode(on: false, reason: "device"), on: scene.socket,
                                                 step: "restored connection off")
        #expect(!scene.rig.router.duckMode(connection: scene.restored))
        #expect(await !scene.rig.env.listener.replyHold.holds(scene.restored))
    }

    @Test(arguments: [false, true])
    func aSameClassSourceKeepsContributing(silent: Bool) async throws {
        let (scene, peer) = try await Self.restoredFrom(silent: silent)
        defer { peer?.cancel(); scene.rig.close() }
        try await Self.off(scene)
        #expect(scene.rig.router.duckMode(connection: scene.source))
        #expect(await scene.rig.env.listener.replyHold.holds(scene.source))
        try await AmbientPrivacyFalseStaleTests.expectPrivateFreshStream(scene.rig, spawn: 3)
    }

    @Test func aSameClassConnectionThatIsNotTheSourceKeepsItsPrivacy() async throws {
        let (scene, peer) = try await Self.restoredFrom(silent: true)
        let (rig, router) = (scene.rig, scene.rig.router)
        defer { peer?.cancel(); rig.close() }
        let (other, connection) = try await rig.connectSilent()
        defer { other.cancel() }
        try await other.send(audio(UUID(), 0))
        #expect(await eventually { router.duckMode(connection: connection) }, "third connection private")
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "third child private proof")
        try await Self.off(scene)
        #expect(router.duckMode(connection: connection) && router.duckMode(connection: scene.source))
        #expect(await rig.env.listener.replyHold.holds(connection))
        try await AmbientPrivacyFalseStaleTests.expectPrivateFreshStream(rig, spawn: 4)
    }

    @Test func anOffAfterRestoreFromTheParkLeavesLaterHoldersPrivate() async throws {
        let rig = try await AmbientPrivacyParkTests.privacyDropped()
        defer { rig.close() }
        let (socket, restored) = try await rig.start(name: RestoreRig.appName, capabilities: [DuckMode.capability])
        let (later, holder) = try await rig.connectSilent()
        defer { later.cancel() }
        try await later.send(audio(UUID(), 0))
        #expect(await eventually { rig.router.duckMode(connection: holder) }, "later holder private")
        #expect(await eventually { rig.router.activePipeline?.hearsAudio == true }, "later child private proof")
        try await Self.off(Scene(rig: rig, source: holder, restored: restored, socket: socket))
        #expect(rig.router.state.withLock { $0.parks.isEmpty })
        #expect(rig.router.duckMode(connection: holder))
        #expect(await rig.env.listener.replyHold.holds(holder))
        try await AmbientPrivacyFalseStaleTests.expectPrivateFreshStream(rig, spawn: 4)
    }

    @Test(arguments: [("pad", "phone"), (nil, "phone"), (nil, nil)] as [(String?, String?)])
    func anotherOrUnknownClassKeepsItsPrivacy(sourceKind: String?, kind: String?) async throws {
        let (scene, peer) = try await Self.restoredFrom(silent: true, sourceKind: sourceKind, kind: kind)
        defer { peer?.cancel(); scene.rig.close() }
        try await Self.off(scene)
        #expect(scene.rig.router.duckMode(connection: scene.source))
        #expect(await scene.rig.env.listener.replyHold.holds(scene.source))
        try await AmbientPrivacyFalseStaleTests.expectPrivateFreshStream(scene.rig, spawn: 3)
    }

    @Test func aReArmedSourceKeepsItsPrivacy() async throws {
        let (scene, peer) = try await Self.restoredFrom(silent: true)
        defer { peer?.cancel(); scene.rig.close() }
        let newer = UUID()
        scene.rig.router.state.withLock { $0.duck[scene.source] = AmbientDuckTimer(token: newer, timer: nil) }
        try await Self.off(scene)
        #expect(scene.rig.router.duckArming(connection: scene.source) == newer)
        #expect(await scene.rig.env.listener.replyHold.holds(scene.source))
        try await AmbientPrivacyFalseStaleTests.expectPrivateFreshStream(scene.rig, spawn: 3)
    }
}
#endif
