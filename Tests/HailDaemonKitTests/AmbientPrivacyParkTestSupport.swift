#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The owner's off settings a test sets (#941): the probe's wait (haild's three seconds unless a test that expects no
/// pong shortens it; a pong ends the wait at once) and a hook before the off decides.
struct PrivacyOffSettings: Sendable {
    static let silent = Self(probeTimeout: .milliseconds(500))
    var probeTimeout: Duration = .seconds(3)
    var offScoping: (@Sendable (UUID) async -> Void)?
}

/// The restore rig's pieces for #941's privacy park tests: segments told apart by their bytes, a held child let go,
/// and what each child read. Synthetic only.
extension RestoreRig {
    /// A synthetic segment of `fill` bytes, the first one of a `resume` start when asked.
    static func segment(_ stream: UUID, _ sequence: Int, fill: UInt8, resume: Bool = false) -> Frame {
        var frame = audio(stream, sequence)
        if case .audio(var payload) = frame.payload {
            (payload.isResume, payload.bytes) = (resume, Data(repeating: fill, count: payload.bytes.count))
            frame.payload = .audio(payload)
        }
        return frame
    }

    /// A device with the app's own claims (#941: Hello name "hail terminal", class `kind`) that never answers a ping,
    /// selecting the rig's target, and its connection id.
    func connectSilent(kind: String? = "phone",
                       capabilities: [String] = ["probe"]) async throws -> (SilentPeer, UUID) {
        let before = await Self.connections(of: env.listener)
        let peer = try await SilentPeer.connect(port: env.port)
        try await peer.send(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: capabilities, deviceName: Self.appName, deviceKind: kind
        )))))
        _ = try await peer.receive()
        try await peer.send(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let nonce = UUID().uuidString
        try await peer.send(sessionFrame(payload: .control(.ping(nonce: nonce))))
        while try await peer.receive().payload != .control(.pong(nonce: nonce)) {}
        let after = await Self.connections(of: env.listener)
        return (peer, try #require(after.subtracting(before).first))
    }

    /// The Hello name every app sends (`HostConnection.deviceName`'s default; `HostConnectionStore` sets no other).
    static let appName = "hail terminal"

    /// Lets a held child write its `started` (`holdStarted`, `holdSpawn`).
    func release() throws { try Data().write(to: fake.directory.appendingPathComponent("go")) }

    /// What the `spawn`th child read from its stdin, once the rig has finished.
    func heard(_ spawn: Int) -> Data {
        (try? Data(contentsOf: fake.directory.appendingPathComponent("audio.\(spawn).raw"))) ?? Data()
    }
}

extension AmbientPrivacyParkTests {
    /// The inspected child is held before its private `started`. No preproof PCM reaches stdin; after that proof,
    /// exactly one distinguishable segment reaches the private child, which hears it in RAM to recognize the exit.
    static func expectHeardOnlyPrivately(_ rig: RestoreRig, on socket: URLSessionWebSocketTask,
                                         spawn: Int) async throws {
        do {
            let pipeline = try await heldPrivateChild(rig, spawn: spawn)
            try await provePreproofDrop(rig, on: socket, pipeline: pipeline)
            try rig.release()
            try #require(await eventually { pipeline.hearsAudio }, "same child confirmed private")
            try #require(rig.router.activePipeline === pipeline, "inspected child remains active")
            let stream = try #require(rig.router.activeStream)
            try await recipientSocketSend(RestoreRig.segment(stream, 2, fill: 0x22), on: socket)
            try await barrier(on: socket, step: "parked postproof audio processed")
            try await drained(rig)
            await rig.finish()
            let heard = rig.heard(spawn)
            #expect(!heard.contains(0x11), "no preproof PCM reaches RightyO")
            #expect(heard.count <= segmentBytes, "no PCM reaches RightyO before its private proof")
            #expect(heard == Data(repeating: 0x22, count: segmentBytes), "exact postproof segment reaches RightyO")
            #expect((try? rig.fake.recorded("argv.\(spawn).txt"))?.contains("--start-private") == true)
        } catch {
            // The original failure is retained; a held fake must also be released and every child reaped on error.
            try? rig.release()
            await rig.finish()
            throw error
        }
    }

    private static func heldPrivateChild(_ rig: RestoreRig, spawn: Int) async throws -> RightyoAmbientPipeline {
        let marker = rig.fake.directory.appendingPathComponent("held-start.\(spawn)").path
        try #require(await eventually {
            FileManager.default.fileExists(atPath: marker)
        }, "inspected child reached its held proof gate")
        let pipeline = try #require(rig.router.activePipeline)
        let arguments = try rig.fake.recorded("argv.\(spawn).txt")
        try #require(arguments.contains(pipeline.session), "held marker belongs to the captured child")
        try #require(arguments.contains("--start-private"), "inspected child starts private")
        try #require(!FileManager.default.fileExists(atPath: rig.fake.directory.appendingPathComponent("go").path))
        try #require(!pipeline.childStarted && !pipeline.hearsAudio, "proof is still held")
        return pipeline
    }

    private static func provePreproofDrop(_ rig: RestoreRig, on socket: URLSessionWebSocketTask,
                                          pipeline: RightyoAmbientPipeline) async throws {
        let stream = try #require(rig.router.activeStream)
        try await recipientSocketSend(RestoreRig.segment(stream, 1, fill: 0x11), on: socket)
        try await barrier(on: socket, step: "parked preproof audio processed")
        try await drained(rig)
        try #require(rig.router.activePipeline === pipeline, "preproof audio uses the captured child")
        #expect(!pipeline.childStarted && !pipeline.hearsAudio, "private proof remains held after processing")
        #expect(pipeline.counters.writtenBytes == 0, "zero PCM written before private proof")
    }

    private static func drained(_ rig: RestoreRig) async throws {
        try #require(await eventually {
            rig.router.state.withLock { $0.queue.isEmpty && !$0.working && !$0.reloading }
        }, "router processed all queued audio before advancing the held proof")
    }
}
#endif
