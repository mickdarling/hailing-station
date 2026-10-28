#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #904: a device re-asserts its privacy (`set_privacy` on) on a new connection before its first stream. The pre-arm is
/// privacy as a restore leaves it (#941): its first start is private, its teardown parks it (R2), its own off is the
/// owner's off, and a stream already running elsewhere in public is left alone until it starts again (R3). Real
/// loopback listener and fake RightyO; every device claim, reply and all PCM are synthetic, every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyPreArmTests {
    /// Connects a device that takes `duck_mode`, pre-arms it, and waits (bounded) for the notice.
    static func preArmed(_ rig: RestoreRig, name: String = "test",
                         kind: String? = "phone") async throws -> (URLSessionWebSocketTask, UUID) {
        let (socket, connection) = try await rig.connect(name: name, kind: kind, capabilities: [DuckMode.capability])
        try await AmbientPrivacySwitchTests.send(true, on: socket)
        try await until(.duckMode(on: true, reason: "device"), on: socket, step: "pre-arm notice")
        try #require(rig.router.duckMode(connection: connection), "the connection is private before any stream")
        return (socket, connection)
    }

    /// Waits, bounded, for `control` on `socket`, a ping at a time.
    static func until(_ control: ControlPayload, on socket: URLSessionWebSocketTask, step: String) async throws {
        var replies: [FramePayload] = []
        for _ in 0..<20 where !replies.contains(.control(control)) {
            replies += try await AmbientPrivacySwitchTests.untilPong(socket, step: step)
        }
        try #require(replies.contains(.control(control)), "\(step): \(replies)")
    }

    /// A normal start after the pre-arm is launched start-private, the agent's replies are held from the pre-arm on,
    /// and no PCM sent before the child's private `started` reaches RightyO.
    @Test func aNormalStartAfterThePreArmIsPrivate() async throws {
        let rig = try await RestoreRig(phrase: nil, holdSpawn: 1)
        defer { rig.close() }
        let (socket, connection) = try await Self.preArmed(rig)
        let listener = rig.env.listener
        #expect(await listener.replyHold.holds(connection), "the agent's replies are held from the pre-arm on")
        #expect(await eventually { rig.details("ambient_privacy_replies").first?.hasPrefix("dropped=") == true },
                "pending replies dropped marker")
        #expect(rig.details("ambient_privacy_prearmed") == ["source=none"])
        try await recipientSocketSend(RestoreRig.segment(UUID(), 0, fill: 0x11), on: socket)
        #expect(await eventually { rig.router.activeConnection() == connection }, "pre-armed start marker")
        #expect(await eventually {
            (try? rig.fake.recorded("argv.1.txt"))?.contains("--start-private") == true
        }, "pre-armed child starts private")
        #expect(rig.router.activePipeline?.hearsAudio == false)
        try rig.release()
        #expect(await eventually { rig.router.activePipeline?.hearsAudio == true }, "private started confirmed")
        await rig.finish()
        #expect(!rig.heard(1).contains(0x11), "no PCM from before the private started reaches RightyO")
        #expect(rig.details("ambient_privacy_restored").isEmpty, "nothing to restore: the pre-arm is kept")
    }

    /// R2: a pre-armed connection that drops before any stream parks its privacy, as any private connection does,
    /// and leaves no state of its own behind; the next fresh start, another device's, is private.
    @Test func aPreArmedConnectionsTeardownParksItsPrivacy() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (socket, connection) = try await Self.preArmed(rig)
        socket.cancel(with: .goingAway, reason: nil)
        let router = rig.router
        #expect(await eventually { router.state.withLock { $0.parks[connection] != nil } }, "pre-arm parked marker")
        #expect(router.state.withLock { state in
            state.duck[connection] == nil && state.privacySources[connection] == nil
                && state.staleCleared[connection] == nil && state.privacyClips[connection] == nil
                && state.privacy[connection] == nil && state.latest[connection] == nil
                && !state.runs.values.contains { $0.connection == connection }
        }, "no per-connection privacy state remains")
        #expect(await !rig.env.listener.replyHold.holds(connection))
        #expect(await eventually { rig.details("ambient_privacy_parked") == ["parks=1 overflow=false"] },
                "parked log marker")
        let (next, other) = try await rig.start(name: "other", kind: "watch")
        #expect(router.duckMode(connection: other))
        #expect(await eventually { rig.details("ambient_privacy_restored").first?.contains("source=park") == true },
                "restored from the pre-arm's park marker")
        try await AmbientPrivacyParkTests.expectHeardOnlyPrivately(rig, on: next, spawn: 1)
    }

    /// The pre-armed connection's own off is the owner's off (#941): its arming and reply hold go, a park it took is
    /// cleared daemon-wide, and its next start is public. A park's heard state is carried, as a restore carries it.
    @Test func itsOwnOffClearsThePreArm() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let parked = UUID()
        rig.router.state.withLock {
            $0.parks[parked] = ParkedPrivacy(connection: parked, device: nil, parkedAt: rig.clock.now(), heard: true)
        }
        let (socket, connection) = try await Self.preArmed(rig)
        let router = rig.router
        #expect(rig.details("ambient_privacy_prearmed") == ["source=park"])
        #expect(router.privacyHeardOn(connection: connection), "a park the owner heard announced answers a status")
        try await AmbientPrivacySwitchTests.send(false, on: socket)
        try await Self.until(.duckMode(on: false, reason: "device"), on: socket, step: "pre-arm off notice")
        #expect(!router.duckMode(connection: connection) && router.state.withLock { $0.parks.isEmpty })
        #expect(await eventually {
            rig.details("ambient_park_discarded") == ["reason=off mode=privacy count=1 overflow=false"]
        },
                "park cleared by the off marker")
        #expect(await eventually { await !rig.env.listener.replyHold.holds(connection) }, "hold released marker")
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        #expect(await eventually { router.activeConnection() == connection }, "start after the off marker")
        #expect(!router.duckMode(connection: connection))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 1))
        await rig.finish()
    }

    /// R3: a pre-arm while another device streams in public leaves that stream alone (public, still listening), and
    /// the pre-armed device's own resume never takes it over. The pre-armed connection counts as a live source, so the
    /// other device's next start is private.
    @Test func aPreArmLeavesAnotherDevicesPublicStream() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (first, listening) = try await rig.start(name: "other", kind: "pad")
        let (socket, connection) = try await Self.preArmed(rig)
        let router = rig.router
        #expect(router.activeConnection() == listening && !router.duckMode(connection: listening))
        #expect(router.activePipeline?.hearsAudio == true)
        try await recipientSocketSend(RestoreRig.segment(UUID(), 0, fill: 0x11, resume: true), on: socket)
        var refusal: String?
        for _ in 0..<4 where refusal == nil {
            let frame = try await receiveFrame(on: socket, step: "pre-armed resume refusal")
            if case .control(.error(.notAllowed, let message, _)) = frame.payload { refusal = message }
        }
        #expect(refusal == AmbientTakeOver.movedMessage(to: "pad"))
        #expect(router.activeConnection() == listening && router.duckMode(connection: connection))
        try await recipientSocketSend(audio(UUID(), 0), on: first)
        #expect(await eventually { router.duckMode(connection: listening) }, "next start private marker")
        #expect(await eventually { rig.details("ambient_privacy_restored").first?.contains("source=live") == true },
                "restored from the pre-armed live source marker")
        await rig.finish()
        #expect((try? rig.fake.recorded("argv.1.txt"))?.contains("--start-private") == false)
        #expect((try? rig.fake.recorded("argv.2.txt"))?.contains("--start-private") == true)
    }
}
#endif
