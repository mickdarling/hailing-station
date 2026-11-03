#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #904 (Jarvis, #967 round 1): a pre-armed connection's own off is the owner's off, exactly as #941 rules it. It
/// clears
/// every existing park and the overflow; every other private connection keeps contributing (#1041). Any other
/// private connection keeps its privacy, its reply hold and its children as they are. Real loopback listener and fake
/// RightyO; every device claim is synthetic, every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyPreArmOffTests {
    /// B pre-arms with no source while A streams in public; then A goes private and parks and the overflow are held.
    /// B's off clears the parks and the overflow; A stays ducked, its replies still held, and
    /// nothing more written to its child.
    @Test func aPreArmedOffLeavesAnotherPrivateStreamAlone() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (_, holder) = try await rig.start(name: "other", kind: "pad")
        let (socket, connection) = try await AmbientPrivacyPreArmTests.preArmed(rig)
        let router = rig.router, listener = rig.env.listener
        #expect(rig.details("ambient_privacy_prearmed") == ["source=none"])
        #expect(await eventually { router.setDuck(true, connection: holder, reason: "voice") == 1 }, "holder private")
        #expect(await eventually { rig.control(1)?.hasSuffix("{\"duck\":true}\n") == true }, "holder written marker")
        let written = rig.control(1)
        let parked = UUID()
        router.state.withLock {
            $0.parks[parked] = ParkedPrivacy(connection: parked, device: nil, parkedAt: rig.clock.now())
            $0.parkOverflow = true
        }
        try await AmbientPrivacySwitchTests.send(false, on: socket)
        try await AmbientPrivacyPreArmTests.until(.duckMode(on: false, reason: "device"), on: socket, step: "B off")
        #expect(!router.duckMode(connection: connection) && router.duckMode(connection: holder))
        #expect(router.state.withLock { $0.parks.isEmpty && !$0.parkOverflow })
        #expect(await eventually {
            rig.details("ambient_park_discarded") == ["reason=off mode=privacy count=1 overflow=true"]
        }, "parks cleared marker")
        #expect(await eventually { await !listener.replyHold.holds(connection) }, "its own hold released marker")
        #expect(await listener.replyHold.holds(holder), "the private stream's replies stay held")
        await rig.finish()
        #expect(rig.control(1) == written, "no write reached the private stream's child after the off")
    }

    /// A private by the owner's voice, then its stream ended (a final segment), so no child of it still listens and
    /// it keeps contributing whether its transport answers pings or stays silent.
    static func privateSourceDone(_ rig: RestoreRig, silent: Bool) async throws -> (SilentPeer?, UUID) {
        let stream = UUID(), router = rig.router
        var (peer, socket): (SilentPeer?, URLSessionWebSocketTask?) = (nil, nil)
        let source: UUID
        if silent {
            let (silentPeer, id) = try await rig.connectSilent(kind: "phone")
            try await silentPeer.send(audio(stream, 0))
            (peer, source) = (silentPeer, id)
        } else {
            let (live, id) = try await rig.connect(name: RestoreRig.appName, kind: "phone")
            try await recipientSocketSend(audio(stream, 0), on: live)
            Task { while (try? await live.receive()) != nil {} }
            (socket, source) = (live, id)
        }
        try #require(await eventually { router.duckMode(connection: source) }, "source holds privacy")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty }, "privacy entry settled")
        let final = audio(stream, 1, final: true)
        if let peer { try await peer.send(final) }
        if let socket { try await recipientSocketSend(final, on: socket) }
        #expect(await eventually {
            router.state.withLock { !$0.runs.values.contains { $0.connection == source && $0.retiredAt == nil } }
        }, "source stream ended marker")
        return (peer, source)
    }

    /// B's pre-arm inherits A's privacy. Its own off leaves A contributing, with replies held, even when silent.
    @Test(arguments: [false, true])
    func aPreArmedOffPreservesItsLiveSource(silent: Bool) async throws {
        let rig = try await RestoreRig(phrase: "stop recording")
        defer { rig.close() }
        let (peer, source) = try await Self.privateSourceDone(rig, silent: silent)
        defer { peer?.cancel() }
        let router = rig.router
        let (socket, connection) = try await AmbientPrivacyPreArmTests.preArmed(rig, name: RestoreRig.appName)
        #expect(rig.details("ambient_privacy_prearmed") == ["source=live"])
        #expect(router.duckMode(connection: connection))
        try await AmbientPrivacySwitchTests.send(false, on: socket)
        try await AmbientPrivacyPreArmTests.until(.duckMode(on: false, reason: "device"), on: socket, step: "B off")
        #expect(router.duckMode(connection: source))
        #expect(await rig.env.listener.replyHold.holds(source))
        try await AmbientPrivacyFalseStaleTests.expectPrivateFreshStream(rig, spawn: 2)
    }
}
#endif
