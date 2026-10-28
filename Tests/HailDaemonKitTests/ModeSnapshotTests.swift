#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #941 PR B: synthetic loopback transport and fake RightyO; no device or physical-audio proof.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ModeSnapshotTests {
    @Test(arguments: [false, true])
    func helloGatesBothFramesAndDoesNotArm(capable: Bool) async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let peer = try await SnapshotPeer(rig, capable: capable)
        defer { peer.close() }
        #expect(peer.hello.capabilities.contains(ModeSnapshot.capability))
        #expect(peer.modes == (capable ? [.control(.duckMode(on: false)), .control(.mediaMode(on: false))] : []))
        #expect(!rig.router.duckMode(connection: peer.connection))
        #expect(await !rig.env.listener.replyHold.holds(peer.connection))
        #expect(rig.router.activeStream == nil)
        #expect(rig.router.state.withLock { $0.privacySources[peer.connection] == nil })
        await rig.finish()
    }

    /// The private snapshot precedes the very first start, whose PCM cannot reach RightyO before its
    /// private `started`. Both normal and resume starts use the existing fake-RightyO admission harness.
    @Test(arguments: [false, true])
    func parkedSnapshotPrecedesPrivateFirstAudio(resume: Bool) async throws {
        let rig = try await RestoreRig(phrase: nil, holdSpawn: 1)
        defer { rig.close() }
        let source = UUID()
        rig.router.state.withLock {
            $0.parks[source] = ParkedPrivacy(connection: source, device: nil, parkedAt: rig.clock.now())
        }
        let peer = try await SnapshotPeer(rig)
        defer { peer.close() }
        try #require(peer.modes == [.control(.duckMode(on: true)), .control(.mediaMode(on: false))])
        #expect(!rig.router.duckMode(connection: peer.connection), "snapshot alone must not pre-arm")
        #expect(rig.router.state.withLock { $0.parks.count } == 1)
        try await recipientSocketSend(RestoreRig.segment(UUID(), 0, fill: 0x11, resume: resume), on: peer.socket)
        #expect(await eventually { rig.router.activeConnection() == peer.connection }, "first start processed")
        #expect(await eventually {
            (try? rig.fake.recorded("argv.1.txt"))?.contains("--start-private") == true
        }, "snapshot's first child launched private")
        #expect(rig.router.activePipeline?.hearsAudio == false)
        try rig.release()
        #expect(await eventually { rig.router.activePipeline?.hearsAudio == true }, "private started confirmed")
        await rig.finish()
        #expect(!rig.heard(1).contains(0x11), "no pre-confirmation PCM reaches RightyO")
    }

    @Test(arguments: [false, true])
    func onlyCapableNeverStreamedOffClearsParksAndOverflow(capable: Bool) async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let source = UUID()
        rig.router.state.withLock {
            $0.parks[source] = ParkedPrivacy(connection: source, device: nil, parkedAt: rig.clock.now())
            $0.parkOverflow = true
        }
        let peer = try await SnapshotPeer(rig, capable: capable)
        defer { peer.close() }
        if capable { #expect(peer.modes.first == .control(.duckMode(on: true))) }
        try await AmbientPrivacySwitchTests.send(false, on: peer.socket)
        let off = try await AmbientPrivacySwitchTests.untilPong(peer.socket, step: "snapshot switch off processed")
        #expect(off == (capable ? [.control(.duckMode(on: false, reason: "device"))] : []))
        #expect(rig.router.state.withLock { $0.parks.isEmpty } == capable)
        #expect(rig.router.state.withLock { $0.parkOverflow } == !capable)
        #expect(!rig.router.duckMode(connection: peer.connection))
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_park_discarded") == (capable
            ? ["reason=off mode=privacy count=1 overflow=true"] : []))
        let (_, next) = try await rig.start()
        #expect(rig.router.duckMode(connection: next) == !capable, "off changes the next start's behavior")
        await rig.finish()
    }

    @Test func overflowAloneAndCountingLiveSourcesAreReported() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        rig.router.state.withLock { $0.parkOverflow = true }
        let overflow = try await SnapshotPeer(rig)
        defer { overflow.close() }
        #expect(overflow.modes.first == .control(.duckMode(on: true)))
        let (source, token) = (UUID(), UUID())
        rig.router.state.withLock {
            $0.parkOverflow = false
            $0.duck[source] = AmbientDuckTimer(token: token, timer: nil)
        }
        let live = try await SnapshotPeer(rig)
        defer { live.close() }
        #expect(live.modes.first == .control(.duckMode(on: true)))
        rig.router.state.withLock { $0.staleCleared[source] = token }
        let stale = try await SnapshotPeer(rig)
        defer { stale.close() }
        #expect(stale.modes.first == .control(.duckMode(on: false)))
        // A stale holder still reports its own next start private, as admission does.
        #expect(rig.router.modeSnapshot(connection: source).first == .duckMode(on: true))
        await rig.finish()
    }

    @Test func capableOffRefusesClosedStoppingAndEndedPeers() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let peer = try await SnapshotPeer(rig)
        rig.router.state.withLock { $0.closed.insert(peer.connection); $0.parkOverflow = true }
        try await AmbientPrivacySwitchTests.send(false, on: peer.socket)
        try await barrier(on: peer.socket, step: "closed snapshot off refused")
        #expect(rig.router.state.withLock { $0.parkOverflow })
        rig.router.state.withLock { _ = $0.closed.remove(peer.connection) }
        let session = try #require(await rig.env.listener.peers.values.first?.session)
        peer.close()
        #expect(await eventually { await RestoreRig.connections(of: rig.env.listener).isEmpty }, "peer ended")
        // A frame already decoded when transport teardown ran still cannot clear a later park.
        _ = await session.receive(sessionFrame(payload: .control(.setPrivacy(on: false))))
        #expect(rig.router.state.withLock { $0.parkOverflow })
        await rig.finish()
        #expect(rig.router.privacyOffFromSnapshot(connection: UUID()) == nil)
        #expect(rig.router.state.withLock { $0.parkOverflow })
    }
}

/// Reads exactly the hello and snapshot, then selects the target. The bounded pong captures any
/// unsolicited frames for an older peer and proves the snapshot is complete before a start can be sent.
struct SnapshotPeer {
    let session: URLSession
    let socket: URLSessionWebSocketTask
    let connection: UUID
    let hello: HelloInfo
    let modes: [FramePayload]

    init(_ rig: RestoreRig, capable: Bool = true) async throws {
        let before = await RestoreRig.connections(of: rig.env.listener)
        (session, socket) = try recipientSocket(port: rig.env.port)
        let transportSession = session
        var completed = false
        defer { if !completed { transportSession.invalidateAndCancel() } }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: capable ? [ModeSnapshot.capability] : [], deviceName: "synthetic",
            deviceKind: "phone"
        )))), on: socket)
        let first = try await receiveFrame(on: socket, step: "snapshot hello")
        guard case .control(.hello(let hello)) = first.payload else {
            throw WebSocketListenerError.invalidReply
        }
        self.hello = hello
        if capable {
            let duck = try await receiveFrame(on: socket, step: "snapshot privacy before any start", within: .seconds(3))
            let media = try await receiveFrame(on: socket, step: "snapshot media before any start", within: .seconds(3))
            modes = [duck.payload, media.payload]
            let extra = try await AmbientPrivacySwitchTests.untilPong(socket, step: "snapshot exactly once")
            #expect(extra.isEmpty)
        } else {
            modes = try await AmbientPrivacySwitchTests.untilPong(socket, step: "legacy receives no snapshot")
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await barrier(on: socket, step: "snapshot selection")
        let after = await RestoreRig.connections(of: rig.env.listener)
        connection = try #require(after.subtracting(before).first)
        completed = true
    }

    func close() { session.invalidateAndCancel() }
}
#endif
