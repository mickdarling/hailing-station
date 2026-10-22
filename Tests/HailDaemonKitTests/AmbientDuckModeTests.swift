#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken duck mode through the listener (#735 H-2): the entry reaches a RightyO that takes it and is
/// confirmed, the auto-end turns it off; an older RightyO or an anonymous session leaves it off and the owner hears
/// "Nothing was sent."; duck and media mode are exclusive. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckModeTests {
    static let duckOn = AmbientAckClip(pcm: Data(repeating: 9, count: 480), sampleRate: 24_000,
                                       text: "Duck mode is on.")
    static let notSent = AmbientAckClip(pcm: Data(repeating: 5, count: 480), sampleRate: 24_000,
                                        text: "Nothing was sent.")
    static let clips = AmbientAckLibrary(clips: ["confirmduckon": [duckOn], "confirmnotsent": [notSent]])

    @Test func duckModeReachesTheChildIsConfirmedAndTimesOut() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, clips: Self.clips,
                                    timeout: 0.5)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Duck mode is on.")
        #expect(await eventually { rig.details("ambient_duck").count == 2 })
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1",
                                                "on=false reason=timeout reported=1"])
        #expect(rig.details("ambient_duck_confirmed") == ["on=true confirm=confirmduckon/0:sent"])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":false}\n")
    }

    /// An older RightyO would skip the line and go on deciding turns: duck mode is not entered, no device is told it
    /// is on, nothing is written to the child, and the owner hears that nothing was sent. Listening goes on.
    @Test func anOlderRightyoLeavesDuckModeOffAndTellsTheOwner() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: false, clips: Self.clips,
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Nothing was sent.")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        let connection = try #require(rig.connection())
        #expect(!rig.env.router.duckMode(connection: connection))
        #expect(rig.details("ambient_ended").isEmpty)
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=0 refused=unsupported"])
        #expect(rig.details("ambient_duck_confirmed") == ["on=true refused=unsupported confirm=confirmnotsent/0:sent"])
        #expect(rig.details("ambient_duck_device").isEmpty)
        #expect(try rig.fake.recorded("control.txt") == "")
    }

    @Test func onAnAnonymousSessionTheOwnerHearsNothingWasSent() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, enrolled: false, clips: Self.clips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Nothing was sent.")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_duck").isEmpty)
        #expect(rig.details("ambient_duck_confirmed") == ["on=true refused=anonymous confirm=confirmnotsent/0:sent"])
        #expect(try rig.fake.recorded("control.txt") == "")
    }

    /// Entering either mode leaves the other, in the child and in the host's state.
    @Test func duckAndMediaModeAreExclusive() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(router.setMedia(true, connection: connection, reason: "voice") == 1)
        #expect(router.mediaMode(connection: connection) && !router.duckMode(connection: connection))
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        #expect(router.duckMode(connection: connection) && !router.mediaMode(connection: connection))
        let lines = ["{\"duck\":true}", "{\"media\":true}", "{\"duck\":false}", "{\"duck\":true}", "{\"media\":false}"]
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == lines.map { $0 + "\n" }.joined() })
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=voice reported=1",
                                                "on=true reason=voice reported=1"])
        await rig.finish()
    }
}

/// One ambient rig with a fake RightyO saying `words`, a device that said hello with `capabilities`, and its stream
/// started. Records every listener event's detail by name.
final class DuckRig: Sendable {
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let session: URLSession
    let socket: URLSessionWebSocketTask
    let stream = UUID()
    private let events: DuckEvents

    /// `script`, when given, replaces the fixture saying `words` as the fake's whole behaviour.
    init(saying words: String = "", advertises: Bool = false, script: String? = nil, enrolled: Bool = true,
         clips: AmbientAckLibrary? = nil, timeout: TimeInterval = AmbientRightyoRouter.defaultDuckTimeout,
         lead: TimeInterval = AmbientRightyoRouter.defaultDuckWarningLead,
         capabilities: [String] = []) async throws {
        fake = try FakeRightyo(script ?? "/bin/cat <&3 > control.txt &\n" + AmbientVoiceDuckTests.fixture(
            saying: words, enrolled: enrolled, advertises: advertises))
        try fake.install(fixture: enrolled ? "enrolled-formed-request.jsonl" : "tool-events.jsonl")
        let events = DuckEvents()
        env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: clips,
                                   replyControl: true, duckTimeout: timeout, duckWarningLead: lead,
                                   onEvent: { event in
            events.list.withLock { $0.append(event) }
        })
        self.events = events
        (session, socket) = try recipientSocket(port: env.port)
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: capabilities, deviceName: "test"
        )))), on: socket)
        _ = try await receiveFrame(on: socket, step: "host hello")
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await barrier(on: socket, step: "selection")
        try await recipientSocketSend(audio(stream, 0), on: socket)
    }

    func details(_ name: String) -> [String] {
        events.list.withLock { $0.filter { $0.event == name }.map { $0.detail ?? "" } }
    }
    /// The connection the ambient stream belongs to, once the stream started.
    func connection() -> UUID? { events.list.withLock { $0.first { $0.event == "ambient_started" }?.sessionID } }

    /// The words of the next frame, which must be a confirmation's text.
    func confirmation() async throws -> String? {
        let frame = try await receiveFrame(on: socket, step: "confirmation words")
        guard case .text(let words) = frame.payload else { return nil }
        return words.text
    }

    func finish() async {
        try? await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
    }

    func close() {
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        fake.cleanUp()
    }
}
/// Every listener event, in order.
final class DuckEvents: Sendable {
    let list = Mutex<[WebSocketListenerEvent]>([])
}
#endif
