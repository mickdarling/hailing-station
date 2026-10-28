#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// A stale verdict (#941, Jarvis at #945 round 3) only stops a source counting as a privacy source for new streams;
/// the source itself stays private (ducked, replies held, never told off). Any later sign of life (a start, a resume,
/// a late pong) lets it count again, and one that never speaks again parks nothing at its teardown. The app's real
/// claims; synthetic only; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyFalseStaleTests {
    struct Cleared {
        let rig: RestoreRig
        let peer: SilentPeer
        let source: UUID
        let restored: (URLSessionWebSocketTask, UUID)
    }

    /// Source A (a peer that never answers a ping; `latePong` answers that long after) is private and open, B is
    /// restored from it, and the owner's off on B judges A stale. A's frames so far are read, so nothing sent to it
    /// after the verdict goes unseen; it is still private.
    static func clearedAsStale(latePong: Duration? = nil) async throws -> Cleared {
        let rig = try await RestoreRig(phrase: "stop recording", privacy: .silent)
        let router = rig.router
        let (peer, source) = try await rig.connectSilent(capabilities: ["probe", DuckMode.capability])
        try await peer.send(audio(UUID(), 0))
        try #require(await eventually { router.duckMode(connection: source) }, "source holds privacy")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty }, "privacy entry settled")
        let restored = try await rig.start(name: RestoreRig.appName)
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        if latePong == nil { _ = try await Self.framesUntilPong(peer) }
        if let latePong { peer.answerPingsLate(after: latePong) }
        _ = router.setDuck(false, connection: restored.1, reason: "voice")
        #expect(await eventually { !rig.details("ambient_privacy_off_scoped").isEmpty }, "off scope marker")
        #expect(rig.details("ambient_privacy_off_scoped") == ["cleared=1 kept=0 \(source)=stale"])
        #expect(router.duckMode(connection: source) && !router.duckMode(connection: restored.1))
        #expect(await rig.env.listener.replyHold.holds(source))
        return Cleared(rig: rig, peer: peer, source: source, restored: restored)
    }

    /// (a) A stale source that starts again, normally (taking listening over) or as a resume once the other stream
    /// ended, was never made public: its child is start-private, hears nothing from before its private proof, its
    /// replies stay held, and it was sent no `duck_mode` off. It counts as a source again: a fresh stream elsewhere
    /// then starts private.
    @Test(arguments: [false, true])
    func aStaleSourceThatStartsAgainIsPrivate(resume: Bool) async throws {
        let cleared = try await Self.clearedAsStale()
        let (rig, router, peer) = (cleared.rig, cleared.rig.router, cleared.peer)
        defer { peer.cancel(); rig.close() }
        #expect(try await Self.framesUntilPong(peer).isEmpty, "nothing sent to the stale source, no off")
        if resume {
            let stream = try #require(router.activeStream)
            try await recipientSocketSend(audio(stream, 1, final: true), on: cleared.restored.0)
            #expect(await eventually { router.activeStream == nil }, "restored stream ended marker")
        }
        let stream = UUID()
        try await peer.send(RestoreRig.segment(stream, 0, fill: 0x11, resume: resume))
        #expect(await eventually { router.activeConnection() == cleared.source }, "source restarted marker")
        #expect(router.duckMode(connection: cleared.source))
        #expect(await rig.env.listener.replyHold.holds(cleared.source))
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_privacy_source_restored") == ["reason=false_stale"])
        #expect(router.state.withLock { $0.staleCleared.isEmpty })
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "its child confirmed private")
        try await peer.send(RestoreRig.segment(stream, 1, fill: 0x22))
        try await Self.expectPrivateFreshStream(rig, spawn: 4)
        await rig.finish()
        #expect(!rig.heard(3).contains(0x11), "no PCM from before its private started")
        #expect((try? rig.fake.recorded("argv.3.txt"))?.contains("--start-private") == true)
    }

    /// (b) A slow peer whose pong comes after the probe's timeout counts as a source again once it does.
    @Test func aLatePongRestoresItsContribution() async throws {
        let cleared = try await Self.clearedAsStale(latePong: .milliseconds(1_500))
        let (rig, router) = (cleared.rig, cleared.rig.router)
        defer { cleared.peer.cancel(); rig.close() }
        #expect(await eventually { router.state.withLock { $0.staleCleared.isEmpty } }, "restored by the late pong")
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_privacy_source_restored") == ["reason=false_stale"])
        #expect(router.duckMode(connection: cleared.source))
        try await Self.expectPrivateFreshStream(rig, spawn: 3)
        await rig.finish()
    }

    /// (c) A stale source that never speaks again parks nothing at its teardown, its mark goes with it, and the next
    /// fresh stream starts public.
    @Test func aStaleSourceThatNeverSpeaksParksNothing() async throws {
        let cleared = try await Self.clearedAsStale()
        let (rig, router) = (cleared.rig, cleared.rig.router)
        defer { rig.close() }
        #expect(router.state.withLock { $0.staleCleared[cleared.source] } != nil)
        cleared.peer.cancel()
        #expect(await eventually { router.state.withLock { $0.privacy[cleared.source] == nil } }, "teardown marker")
        await rig.drainMeetingChanges()
        #expect(router.state.withLock { $0.staleCleared.isEmpty && $0.parks.isEmpty })
        #expect(rig.details("ambient_privacy_parked").isEmpty)
        #expect(rig.details("ambient_privacy_source_restored").isEmpty)
        let (_, next) = try await rig.start(name: RestoreRig.appName)
        #expect(!router.duckMode(connection: next))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 3))
        await rig.finish()
    }

    /// (d) A source still streaming when the off judges it is alive, whatever its ping: kept counting, never judged
    /// stale.
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
        #expect(router.duckMode(connection: source) && router.state.withLock { $0.staleCleared.isEmpty })
        await rig.finish()
    }

    /// (e) While a source is judged stale and has not spoken, a host clip that respects the hold (#913) is held, and
    /// nothing at all is sent to it.
    @Test func aStaleSourcesRepliesStayHeld() async throws {
        let cleared = try await Self.clearedAsStale()
        let (rig, peer) = (cleared.rig, cleared.peer)
        defer { peer.cancel(); rig.close() }
        let listener = rig.env.listener
        #expect(await listener.acknowledgeAmbient(connection: cleared.source, target: RecipientTestRig.target,
                                                  clip: RestoreRig.resumed, heldWhilePrivate: true)
                == "suppressed_privacy")
        #expect(await listener.replyHold.holds(cleared.source))
        #expect(try await Self.framesUntilPong(peer).isEmpty, "nothing sent to the stale source")
        await rig.finish()
    }

    /// (f) A later owner's off elsewhere does not report a source a stale verdict already excluded (round 5 P3-1).
    @Test func anExcludedSourceIsNotListedByALaterOff() async throws {
        let cleared = try await Self.clearedAsStale()
        let (rig, router) = (cleared.rig, cleared.rig.router)
        defer { cleared.peer.cancel(); rig.close() }
        let (_, other) = try await rig.connect(name: RestoreRig.appName)
        router.state.withLock { $0.duck[other] = AmbientDuckTimer(token: UUID(), timer: nil) }
        _ = router.setDuck(false, connection: other, reason: "voice")
        #expect(!router.duckMode(connection: other) && router.duckMode(connection: cleared.source))
        // The scope line would be written by a task off the lock at once; give it time to show it is not.
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.details("ambient_privacy_off_scoped") == ["cleared=1 kept=0 \(cleared.source)=stale"])
        await rig.finish()
    }

    /// A fresh stream on a new connection starts private: some source still counts.
    static func expectPrivateFreshStream(_ rig: RestoreRig, spawn: Int) async throws {
        let (_, fresh) = try await rig.start(name: RestoreRig.appName)
        #expect(rig.router.duckMode(connection: fresh))
        #expect(await eventually {
            (try? rig.fake.recorded("argv.\(spawn).txt"))?.contains("--start-private") == true
        }, "fresh stream start-private marker")
    }

    /// The peer's frames before the pong to a protocol ping sent now (WebSocket control frames aside).
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
