#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ModeSnapshotHeldElsewhereTests {
    /// A is a real connected, pre-armed holder. B never streamed and its off must report what its first start does.
    @Test(arguments: [false, true])
    func unarmedOffReportsEffectivePrivacyAndFirstStart(hasHolder: Bool) async throws {
        let rig = try await RestoreRig(phrase: nil, holdSpawn: 1)
        defer { rig.close() }
        if hasHolder {
            _ = try await AmbientPrivacyPreArmTests.preArmed(rig)
        } else {
            rig.router.state.withLock { $0.parkOverflow = true }
        }
        let peer = try await SnapshotPeer(rig)
        defer { peer.close() }
        #expect(peer.modes.first == .control(.duckMode(on: true)))
        try await AmbientPrivacySwitchTests.send(false, on: peer.socket)
        let reply = try await AmbientPrivacySwitchTests.untilPong(peer.socket, step: "effective off response")
        let reason = hasHolder ? "held_elsewhere" : "device"
        #expect(reply == [.control(.duckMode(on: hasHolder, reason: reason))])
        #expect(rig.router.state.withLock { $0.parks.isEmpty && !$0.parkOverflow })
        #expect(!rig.router.duckMode(connection: peer.connection), "the response must not arm B")
        #expect(await !rig.env.listener.replyHold.holds(peer.connection), "the response must not hold replies")
        #expect(rig.router.activeStream == nil, "the response must not start a child")
        try await firstStart(rig, peer: peer, privateStart: hasHolder)
        await rig.finish()
        if hasHolder { #expect(!rig.heard(1).contains(0x11), "no private PCM before started reaches RightyO") }
    }

    private func firstStart(_ rig: RestoreRig, peer: SnapshotPeer, privateStart: Bool) async throws {
        try await recipientSocketSend(RestoreRig.segment(UUID(), 0, fill: 0x11), on: peer.socket)
        #expect(await eventually { rig.router.activeConnection() == peer.connection }, "B's first start processed")
        #expect(await eventually {
            guard let argv = try? rig.fake.recorded("argv.1.txt") else { return false }
            return argv.contains("--start-private") == privateStart
        }, "B's first child matches the off response")
        #expect(rig.router.activePipeline?.hearsAudio == !privateStart)
        try rig.release()
        #expect(await eventually { rig.router.activePipeline?.childStarted == true }, "started confirmed")
    }
}
#endif
