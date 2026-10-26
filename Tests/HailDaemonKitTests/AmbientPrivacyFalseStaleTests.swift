#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// An owner's off clears a stale-looking restore source only provisionally (#941, Jarvis at #945 round 3): any later
/// sign of life (a start, a resume, a late pong) puts its privacy back before any of its audio is admitted, and one
/// that never speaks again stays cleared, so its teardown parks nothing. The app's real claims; synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyFalseStaleTests {
    struct Cleared {
        let rig: RestoreRig
        let peer: SilentPeer
        let source: UUID
        let restored: (URLSessionWebSocketTask, UUID)
    }

    /// Source A (a peer that never answers a ping; `latePong` answers that long after) is private and open, B is
    /// restored from it, and the owner's off on B clears A as stale.
    static func clearedAsStale(latePong: Duration? = nil) async throws -> Cleared {
        let rig = try await RestoreRig(phrase: "stop recording", privacy: .silent)
        let router = rig.router
        let (peer, source) = try await rig.connectSilent(capabilities: ["probe", DuckMode.capability])
        try await peer.send(audio(UUID(), 0))
        try #require(await eventually { router.duckMode(connection: source) }, "source holds privacy")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty }, "privacy entry settled")
        let restored = try await rig.start(name: RestoreRig.appName)
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        if let latePong { peer.answerPingsLate(after: latePong) }
        _ = router.setDuck(false, connection: restored.1, reason: "voice")
        #expect(await eventually { !rig.details("ambient_privacy_off_scoped").isEmpty }, "off scope marker")
        #expect(rig.details("ambient_privacy_off_scoped") == ["cleared=1 kept=0 \(source)=stale"])
        return Cleared(rig: rig, peer: peer, source: source, restored: restored)
    }

    /// (a) A cleared source that starts again, normally (taking listening over) or as a resume once the other stream
    /// ended, is private before its start is admitted: its child is start-private and hears nothing from before its
    /// private proof, and its device is told `duck_mode` on with reason `device`.
    @Test(arguments: [false, true])
    func aClearedSourceThatStartsAgainIsPrivateFirst(resume: Bool) async throws {
        let cleared = try await Self.clearedAsStale()
        let (rig, router, peer) = (cleared.rig, cleared.rig.router, cleared.peer)
        defer { peer.cancel(); rig.close() }
        #expect(!router.duckMode(connection: cleared.source))
        if resume {
            let stream = try #require(router.activeStream)
            try await recipientSocketSend(audio(stream, 1, final: true), on: cleared.restored.0)
            #expect(await eventually { router.activeStream == nil }, "restored stream ended marker")
        }
        let stream = UUID()
        try await peer.send(RestoreRig.segment(stream, 0, fill: 0x11, resume: resume))
        #expect(await eventually { router.activeConnection() == cleared.source }, "source restarted marker")
        #expect(router.duckMode(connection: cleared.source))
        #expect(await eventually {
            rig.details("privacy_reapplied") == ["reason=false_stale to=\(cleared.source)"]
        }, "re-applied log marker")
        try await Self.expectTold(peer)
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "its child confirmed private")
        try await peer.send(RestoreRig.segment(stream, 1, fill: 0x22))
        await rig.finish()
        #expect(!rig.heard(3).contains(0x11), "no PCM from before its private started")
        #expect((try? rig.fake.recorded("argv.3.txt"))?.contains("--start-private") == true)
    }

    /// (b) A slow peer whose pong comes after the probe's timeout is cleared, then given its privacy back by the pong.
    @Test func aLatePongPutsPrivacyBack() async throws {
        let cleared = try await Self.clearedAsStale(latePong: .milliseconds(1_500))
        let (rig, router) = (cleared.rig, cleared.rig.router)
        defer { cleared.peer.cancel(); rig.close() }
        #expect(await eventually { router.duckMode(connection: cleared.source) }, "re-applied by the late pong")
        #expect(await eventually {
            rig.details("privacy_reapplied") == ["reason=false_stale to=\(cleared.source)"]
        }, "re-applied log marker")
        #expect(await eventually { await rig.env.listener.replyHold.holds(cleared.source) }, "hold set again")
        await rig.finish()
    }

    /// (c) A cleared source that never speaks again and tears down parks nothing, its mark goes with it, and the next
    /// stream starts public.
    @Test func aClearedSourceThatNeverSpeaksStaysCleared() async throws {
        let cleared = try await Self.clearedAsStale()
        let (rig, router) = (cleared.rig, cleared.rig.router)
        defer { rig.close() }
        #expect(router.state.withLock { $0.staleCleared[cleared.source] } != nil)
        cleared.peer.cancel()
        #expect(await eventually { router.state.withLock { $0.privacy[cleared.source] == nil } }, "teardown marker")
        await rig.drainMeetingChanges()
        #expect(router.state.withLock { $0.staleCleared.isEmpty && $0.parkedPrivacy == nil })
        #expect(rig.details("ambient_privacy_parked").isEmpty && rig.details("privacy_reapplied").isEmpty)
        let (_, next) = try await rig.start(name: RestoreRig.appName)
        #expect(!router.duckMode(connection: next))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 3))
        await rig.finish()
    }

    /// (d) A source still streaming when the off judges it is alive, whatever its ping: kept, never cleared.
    @Test func aSourceStillStreamingIsKept() async throws {
        let rig = try await RestoreRig(phrase: "stop recording", privacy: .silent)
        defer { rig.close() }
        let router = rig.router
        let (peer, source) = try await rig.connectSilent()
        defer { peer.cancel() }
        try await peer.send(audio(UUID(), 0))
        try #require(await eventually { router.duckMode(connection: source) }, "source holds privacy")
        let (_, restored) = try await rig.start(name: RestoreRig.appName)
        try await peer.send(audio(UUID(), 0))
        #expect(await eventually { router.activeConnection() == source }, "source took listening back")
        _ = router.setDuck(false, connection: restored, reason: "voice")
        #expect(await eventually { !rig.details("ambient_privacy_off_scoped").isEmpty }, "off scope marker")
        #expect(rig.details("ambient_privacy_off_scoped") == ["cleared=0 kept=1 \(source)=live"])
        #expect(router.duckMode(connection: source))
        await rig.finish()
    }

    /// Reads the peer's frames until `duck_mode` on with reason `device`.
    static func expectTold(_ peer: SilentPeer) async throws {
        for _ in 0..<12 {
            let payload = try await peer.receive().payload
            guard payload != .control(.duckMode(on: true, reason: "device")) else { return }
        }
        Issue.record("no duck_mode on with reason device")
    }
}
#endif
