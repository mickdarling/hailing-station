#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The device end control for duck mode (#735 H-4): `end_duck_mode` ends duck mode for the sending connection only,
/// with reason `device`, exactly as the spoken exit does but without a clip; it is advertised and admitted only with
/// ambient listening, never starts duck mode, and does nothing while duck mode is off. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientDuckDeviceEndTests {
    static let duckOff = AmbientAckClip(pcm: Data(repeating: 3, count: 480), sampleRate: 24_000,
                                        text: "Duck mode is off.")

    @Test func theDeviceEndsItsOwnDuckModeWithReasonDevice() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true,
                                    clips: AmbientAckLibrary(clips: ["confirmduckoff": [Self.duckOff]]),
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        let on = try await receiveFrame(on: rig.socket, step: "duck mode on")
        guard case .control(.duckMode(true, "voice", _?)) = on.payload else {
            Issue.record("expected duck_mode on, got \(on.payload)")
            return
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.endDuckMode)), on: rig.socket)
        let off = try await receiveFrame(on: rig.socket, step: "duck mode off")
        #expect(off.payload == .control(.duckMode(on: false, reason: "device")))
        let connection = try #require(rig.connection())
        #expect(!rig.env.router.duckMode(connection: connection))
        // A second end while off changes nothing and is not answered: the next frame is the barrier's own pong.
        try await recipientSocketSend(sessionFrame(payload: .control(.endDuckMode)), on: rig.socket)
        try await barrier(on: rig.socket, step: "second end")
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=device reported=1"])
        #expect(rig.details("ambient_duck_device") == ["on=true device=sent", "on=false device=sent"])
        // The owner acted on the screen: no clip, and the voice confirmation log has only the entry.
        #expect(rig.details("ambient_duck_confirmed").count == 1)
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":false}\n")
    }

    /// Another device's connection cannot end this one's duck mode: the command carries no connection, and the host
    /// uses the sender's own.
    @Test func anotherConnectionCannotEndIt() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, timeout: 30)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        let (session, other) = try recipientSocket(port: rig.env.port)
        defer {
            other.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: [DuckMode.capability], deviceName: "other"
        )))), on: other)
        _ = try await receiveFrame(on: other, step: "other hello")
        try await recipientSocketSend(sessionFrame(payload: .control(.endDuckMode)), on: other)
        try await barrier(on: other, step: "other end")
        #expect(rig.env.router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1"])
    }

    /// While duck mode is off the control starts nothing, writes nothing to the child and sends nothing back.
    @Test func itNeverStartsDuckMode() async throws {
        let rig = try await DuckRig(saying: "Synthetic words.", advertises: true, capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        try await recipientSocketSend(sessionFrame(payload: .control(.endDuckMode)), on: rig.socket)
        try await barrier(on: rig.socket, step: "end while off")
        await rig.finish()
        #expect(rig.details("ambient_duck").isEmpty && rig.details("ambient_duck_device").isEmpty)
        #expect(try rig.fake.recorded("control.txt") == "")
    }

    /// Without ambient listening the host neither advertises nor admits it, like `ambient_input`.
    @Test func withoutAmbientListeningItIsNeitherAdvertisedNorAdmitted() async {
        let frame = Frame(timestamp: 1, source: "terminal", payload: .control(.endDuckMode))
        let plain = PersonalTerminalAuthorizer()
        #expect(!plain.capabilities.contains(DuckMode.endCapability))
        #expect(await plain.authorize(frame) == .deny)
        #expect(await ConnectionProbeAuthorizer().authorize(frame) == .deny)
        let gated = PersonalTerminalAuthorizer(
            ambientAudio: AmbientAudioGate(target: "tmux:a", sink: EndSink(), sweepInterval: nil)
        )
        #expect(gated.capabilities.contains(DuckMode.endCapability))
        #expect(await gated.authorize(frame) == .allow)
    }

    /// The gate hands the end on for exactly the connection it is given, and a sink without duck mode ignores it.
    @Test func theGateHandsOnTheConnectionAsGiven() async {
        let sink = EndSink(), connection = UUID()
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        await gate.endDuck(connection: connection)
        #expect(sink.ends.withLock { $0 } == [connection])
        struct Plain: AmbientAudioSink { func ambientAudio(_ event: AmbientAudioEvent) {} }
        Plain().ambientDuckEnd(connection: connection)
    }
}

/// Records each duck end it is handed.
private final class EndSink: AmbientAudioSink {
    let ends = Mutex<[UUID]>([])
    func ambientAudio(_ event: AmbientAudioEvent) {}
    func ambientDuckEnd(connection: UUID) { ends.withLock { $0.append(connection) } }
}
#endif
