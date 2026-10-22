#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Privacy mode (internally duck) through the listener (#735 S-2): the owner's entry reaches a RightyO that keeps
/// nothing (`duck` v2) and is confirmed, the auto-end turns it off; a v1 or older RightyO leaves it off and the speaker
/// hears "Nothing was sent."; a negation hears "Still recording."; RightyO's exit and status events are carried out and
/// answered; privacy and media mode are exclusive. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckModeTests {
    static func clip(_ text: String, _ byte: UInt8) -> AmbientAckClip {
        AmbientAckClip(pcm: Data(repeating: byte, count: 480), sampleRate: 24_000, text: text)
    }
    static let clips = AmbientAckLibrary(clips: [
        "confirmprivacyon": [clip("Privacy on. I'm only listening for my name.", 9)],
        "confirmprivacyoff": [clip("Recording again.", 8)],
        "confirmprivacystatus": [clip("Privacy on. I'm only listening for my name.", 7)],
        "confirmstillrecording": [clip("Still recording.", 6)],
        "confirmnotsent": [clip("Nothing was sent.", 5)]
    ])

    @Test func privacyReachesTheChildIsConfirmedAndTimesOut() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true, clips: Self.clips,
                                    timeout: 0.5)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Privacy on. I'm only listening for my name.")
        #expect(await eventually { rig.details("ambient_duck").count == 2 })
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1",
                                                "on=false reason=timeout reported=1"])
        #expect(rig.details("ambient_duck_confirmed") == ["on=true playback=idle confirm=confirmprivacyon/0:sent"])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":false}\n")
    }

    /// A v1 RightyO still transcribes while ducked and an older one would skip the line: privacy is not entered (fail
    /// closed), no device is told it is on, nothing is written to the child, and the speaker hears that nothing was
    /// sent. Listening goes on.
    @Test(arguments: [false, true]) func aVersionOneOrOlderRightyoRefusesPrivacy(_ v1: Bool) async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: v1, version: 1, clips: Self.clips,
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Nothing was sent.")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        let connection = try #require(rig.connection())
        #expect(!rig.env.router.duckMode(connection: connection))
        #expect(rig.details("ambient_ended").isEmpty)
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=0 refused=unsupported"])
        #expect(rig.details("ambient_duck_confirmed") == [
            "on=true refused=unsupported_version confirm=confirmnotsent/0:sent"
        ])
        #expect(rig.details("ambient_duck_device").isEmpty)
        #expect(try rig.fake.recorded("control.txt") == "")
    }

    /// Owner only: an anonymous session's entry is ignored with no clip, held back, and logged `refused=not_owner`.
    @Test func anAnonymousSessionsEntryIsRefused() async throws {
        let rig = try await DuckRig(saying: "go private", advertises: true, enrolled: false, clips: Self.clips)
        defer { rig.close() }
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_duck").isEmpty)
        #expect(rig.details("ambient_duck_confirmed") == ["on=true refused=not_owner confirm=unreported"])
        #expect(try rig.fake.recorded("control.txt") == "")
    }

    @Test func aNegationPlaysStillRecordingAndChangesNothing() async throws {
        let rig = try await DuckRig(saying: "Rightyo, do not stop recording.", advertises: true, clips: Self.clips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Still recording.")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_duck").isEmpty)
        #expect(rig.details("ambient_duck_confirmed") == ["negated confirm=confirmstillrecording/0:sent"])
        #expect(try rig.fake.recorded("control.txt") == "")
    }

    /// The owner's transcript enters, then RightyO's status and exit events: the status clip while private, then the
    /// exit turns privacy off, tells the device and confirms "Recording again.".
    @Test func statusAndExitEventsAreAnswered() async throws {
        let rig = try await DuckRig(script: "/bin/cat <&3 > control.txt &\n"
                                        + AmbientPrivacyEventTests.enterThen(["status", "exit", "status"]),
                                    clips: Self.clips, capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 4 })
        let connection = try #require(rig.connection())
        #expect(!rig.env.router.duckMode(connection: connection))
        #expect(await eventually { rig.details("ambient_duck_device").count == 2 })
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=voice reported=1"])
        #expect(rig.details("ambient_duck_confirmed") == [
            "on=true playback=idle confirm=confirmprivacyon/0:sent",
            "status on=true confirm=confirmprivacystatus/0:sent",
            "on=false confirm=confirmprivacyoff/0:sent", "status on=false confirm=unreported"
        ])
        #expect(rig.details("ambient_duck_device") == ["on=true device=sent", "on=false device=sent"])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":false}\n")
    }

    /// Entering either mode leaves the other, in the child and in the host's state.
    @Test func privacyAndMediaModeAreExclusive() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true)
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
    init(saying words: String = "", advertises: Bool = false, version: Int = 2, script: String? = nil,
         enrolled: Bool = true,
         clips: AmbientAckLibrary? = nil, timeout: TimeInterval = AmbientRightyoRouter.defaultDuckTimeout,
         capabilities: [String] = []) async throws {
        fake = try FakeRightyo(script ?? "/bin/cat <&3 > control.txt &\n" + AmbientPrivacyEntryTests.fixture(
            saying: words, enrolled: enrolled, advertises: advertises, version: version))
        try fake.install(fixture: enrolled ? "enrolled-formed-request.jsonl" : "tool-events.jsonl")
        let events = DuckEvents()
        env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: clips,
                                   replyControl: true, duckTimeout: timeout, onEvent: { event in
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
