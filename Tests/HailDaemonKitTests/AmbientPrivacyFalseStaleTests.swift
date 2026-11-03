#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Former false-stale scenarios (#941): #1041 preserves the holder before, during and after any later life.
/// Synthetic loopback peers and fake RightyO; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyFalseStaleTests {
    @Test(arguments: [false, true])
    func aSilentSourceThatStartsAgainIsPrivate(resume: Bool) async throws {
        let (scene, silent) = try await AmbientPrivacyOffScopeTests.restoredFrom(silent: true)
        let peer = try #require(silent), rig = scene.rig, router = scene.rig.router
        defer { peer.cancel(); rig.close() }
        _ = try await Self.framesUntilPong(peer)
        try await AmbientPrivacyOffScopeTests.off(scene)
        #expect(try await Self.framesUntilPong(peer).isEmpty, "nothing sent to the source, no off")
        if resume {
            let stream = try #require(router.activeStream)
            try await recipientSocketSend(audio(stream, 1, final: true), on: scene.socket)
            #expect(await eventually { router.activeStream == nil }, "restored stream ended")
        }
        let stream = UUID()
        try await peer.send(RestoreRig.segment(stream, 0, fill: 0x11, resume: resume))
        #expect(await eventually { router.activeConnection() == scene.source }, "source restarted")
        #expect(router.duckMode(connection: scene.source))
        #expect(await rig.env.listener.replyHold.holds(scene.source))
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "source private started confirmed")
        try await peer.send(RestoreRig.segment(stream, 1, fill: 0x22))
        try await Self.expectPrivateFreshStream(rig, spawn: 4)
        #expect(!rig.heard(3).contains(0x11), "no PCM from before its private started")
        #expect((try? rig.fake.recorded("argv.3.txt"))?.contains("--start-private") == true)
    }

    @Test func aSilentSourceThatNeverSpeaksParksItsPrivacy() async throws {
        let (scene, silent) = try await AmbientPrivacyOffScopeTests.restoredFrom(silent: true)
        let peer = try #require(silent), rig = scene.rig, router = scene.rig.router
        defer { peer.cancel(); rig.close() }
        try await AmbientPrivacyOffScopeTests.off(scene)
        peer.cancel()
        #expect(await eventually { router.state.withLock { $0.parks[scene.source] != nil } }, "source parked")
        #expect(!router.duckMode(connection: scene.source))
        #expect(await !rig.env.listener.replyHold.holds(scene.source))
        #expect(await eventually { rig.details("ambient_privacy_parked") == ["parks=1 overflow=false"] },
                "park log queued")
        try await Self.expectPrivateFreshStream(rig, spawn: 3)
    }

    @Test func aSourceStillStreamingIsKept() async throws {
        let (scene, silent) = try await AmbientPrivacyOffScopeTests.restoredFrom(silent: true)
        let peer = try #require(silent), rig = scene.rig, router = scene.rig.router
        defer { peer.cancel(); rig.close() }
        try await peer.send(audio(UUID(), 0))
        #expect(await eventually { router.activeConnection() == scene.source }, "source took listening back")
        try await AmbientPrivacyOffScopeTests.off(scene)
        #expect(router.duckMode(connection: scene.source))
        #expect(await rig.env.listener.replyHold.holds(scene.source))
        try await Self.expectPrivateFreshStream(rig, spawn: 4)
    }

    @Test func aSilentSourcesRepliesStayHeld() async throws {
        let (scene, silent) = try await AmbientPrivacyOffScopeTests.restoredFrom(silent: true)
        let peer = try #require(silent), rig = scene.rig
        defer { peer.cancel(); rig.close() }
        _ = try await Self.framesUntilPong(peer)
        try await AmbientPrivacyOffScopeTests.off(scene)
        #expect(await rig.env.listener.acknowledgeAmbient(connection: scene.source, target: RecipientTestRig.target,
                                                         clip: RestoreRig.resumed, heldWhilePrivate: true)
                == "suppressed_privacy")
        #expect(await rig.env.listener.replyHold.holds(scene.source))
        #expect(try await Self.framesUntilPong(peer).isEmpty, "neither off nor reply sent to the source")
        try await Self.expectPrivateFreshStream(rig, spawn: 3)
    }

    /// A fresh stream remains private, holds replies, and admits no PCM before the child's private proof.
    static func expectPrivateFreshStream(_ rig: RestoreRig, spawn: Int) async throws {
        let (socket, fresh) = try await rig.start(name: RestoreRig.appName)
        #expect(rig.router.duckMode(connection: fresh))
        #expect(await rig.env.listener.replyHold.holds(fresh))
        #expect(await eventually {
            (try? rig.fake.recorded("argv.\(spawn).txt"))?.contains("--start-private") == true
        }, "fresh stream start-private")
        try await AmbientPrivacyParkTests.expectHeardOnlyPrivately(rig, on: socket, spawn: spawn)
    }

    /// Drain all frames preceding a protocol pong; the silent transport never answers host WebSocket pings.
    static func framesUntilPong(_ peer: SilentPeer) async throws -> [FramePayload] {
        let nonce = UUID().uuidString
        try await peer.send(sessionFrame(payload: .control(.ping(nonce: nonce))))
        var frames: [FramePayload] = []
        for _ in 0..<16 {
            let payload = try await peer.receive().payload
            guard payload != .control(.pong(nonce: nonce)) else { return frames }
            frames.append(payload)
        }
        Issue.record("no pong within sixteen frames")
        return frames
    }
}
#endif
