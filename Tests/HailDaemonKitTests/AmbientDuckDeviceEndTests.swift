#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The device end control for duck mode (#735 H-4): `end_duck_mode` ends duck mode for the sending connection only,
/// with reason `device`, exactly as the spoken exit does, and plays `confirm-duck-off/` once; it is advertised and
/// admitted only with ambient listening, never starts duck mode, and does nothing at all while duck mode is off or
/// once the arming it read has ended. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientDuckDeviceEndTests {
    static let duckOff = AmbientAckClip(pcm: Data(repeating: 3, count: 480), sampleRate: 24_000,
                                        text: "Duck mode is off.")
    static let clips = AmbientAckLibrary(clips: ["confirmduckoff": [Self.duckOff]])

    /// Sends a ping and reads up to the pong, returning the words of every text frame on the way.
    static func wordsUntilPong(_ socket: URLSessionWebSocketTask, step: String) async throws -> [String] {
        let nonce = UUID().uuidString
        try await recipientSocketSend(sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket)
        var words: [String] = []
        for _ in 0..<32 {
            let frame = try await receiveFrame(on: socket, step: step)
            if frame.payload == .control(.pong(nonce: nonce)) { return words }
            if case .text(let text) = frame.payload { words.append(text.text) }
        }
        Issue.record("no pong at \(step)")
        return words
    }

    @Test func theDeviceEndsItsOwnDuckModeWithReasonDeviceAndTheClipPlaysOnce() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, clips: Self.clips,
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        let on = try await receiveFrame(on: rig.socket, step: "duck mode on")
        guard case .control(.duckMode(true, "voice", _?)) = on.payload else {
            Issue.record("expected duck_mode on, got \(on.payload)")
            return
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.endDuckMode)), on: rig.socket)
        var (sawOff, words) = (false, [String]())
        for _ in 0..<16 where !(sawOff && !words.isEmpty) {
            let frame = try await receiveFrame(on: rig.socket, step: "duck mode off and its clip")
            if frame.payload == .control(.duckMode(on: false, reason: "device")) { sawOff = true }
            if case .text(let text) = frame.payload { words.append(text.text) }
        }
        #expect(sawOff && words == ["Duck mode is off."])
        let connection = try #require(rig.connection())
        #expect(!rig.env.router.duckMode(connection: connection))
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        // M07a: a second end while off emits no event at all, plays nothing and sends nothing back.
        let before = await rig.settledEvents()
        try await recipientSocketSend(sessionFrame(payload: .control(.endDuckMode)), on: rig.socket)
        #expect(try await Self.wordsUntilPong(rig.socket, step: "second end").isEmpty)
        #expect(await rig.settledEvents() == before)
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=device reported=1"])
        #expect(rig.details("ambient_duck_device") == ["on=true device=sent", "on=false device=sent"])
        #expect(rig.details("ambient_duck_confirmed").last == "on=false reason=device confirm=confirmduckoff/0:sent")
        #expect(rig.details("ambient_duck_confirmed").filter { $0.contains("confirmduckoff") }.count == 1)
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":false}\n")
    }

    /// F1: an end for an arming that has since ended and been re-armed does nothing to the new one: no second off,
    /// no `{"duck":false}`, no log line and no clip.
    @Test func anEndForAStaleArmingDoesNothing() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, clips: Self.clips, timeout: 30)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection()), router = rig.env.router
        let stale = try #require(router.duckTimer(connection: connection)).token
        #expect(router.setDuck(false, connection: connection, reason: "voice") == 1)
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        let before = await rig.settledEvents()
        router.endDuck(connection: connection, armedAs: stale)
        #expect(await rig.settledEvents() == before)
        #expect(router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=voice reported=1",
                                                "on=true reason=voice reported=1"])
        #expect(!rig.details("ambient_duck_confirmed").contains { $0.contains("reason=device") })
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":false}\n{\"duck\":true}\n")
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

    /// M07a: while duck mode is off the control starts nothing and emits no event at all; nothing is written to the
    /// child, played or sent back.
    @Test func itNeverStartsDuckMode() async throws {
        let rig = try await DuckRig(saying: "Synthetic words.", advertises: true, clips: Self.clips,
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let before = await rig.settledEvents()
        try await recipientSocketSend(sessionFrame(payload: .control(.endDuckMode)), on: rig.socket)
        #expect(try await Self.wordsUntilPong(rig.socket, step: "end while off").isEmpty)
        #expect(await rig.settledEvents() == before)
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
