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
        "confirmprivacyunavailable": [clip("I can't listen privately right now.", 4)],
        "confirmprivacyhint": [clip("To go private, say stop recording on its own.", 3)],
        "confirmnotsent": [clip("Nothing was sent.", 5)]
    ])

    /// Round 2: no auto-end; with the reserved timeout short and time past it, privacy is still on.
    @Test func privacyReachesTheChildIsConfirmedAndNeverTimesOut() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true, clips: Self.clips,
                                    timeout: 0.5)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Privacy on. I'm only listening for my name.")
        let connection = try #require(rig.connection())
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(rig.env.router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1"])
        #expect(rig.details("ambient_duck_confirmed") == ["on=true playback=idle confirm=confirmprivacyon/0:sent"])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n")
    }

    /// A v1 RightyO still transcribes while ducked, a v2 one never acks (#735 S-8) and an older one would skip the
    /// line: privacy is not entered (fail closed), no device is told it is on, nothing is written to the child, and the
    /// speaker hears that nothing was sent. Listening goes on.
    @Test(arguments: [nil, 1, 2] as [Int?]) func aVersionTwoOrOlderRightyoRefusesPrivacy(_ version: Int?) async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: version != nil,
                                    version: version ?? 1, clips: Self.clips, capabilities: [DuckMode.capability])
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
        #expect(rig.details("ambient_duck_confirmed") == ["refused=not_owner confirm=unreported"])
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
        let rig = try await DuckRig(script: FakeRightyo.ackingControl() + "\n"
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

    /// Start and ack deadlines unless a test sets its own (#836): past any loaded runner's stall.
    static let deadline: TimeInterval = 30

    /// `script`, when given, replaces the fixture saying `words` as the fake's whole behaviour.
    init(saying words: String = "", advertises: Bool = false, version: Int = 3, script: String? = nil,
         enrolled: Bool = true,
         clips: AmbientAckLibrary? = nil, timeout: TimeInterval = AmbientRightyoRouter.defaultDuckTimeout,
         capabilities: [String] = [],
         startDeadline: TimeInterval = DuckRig.deadline, ackDeadline: TimeInterval = DuckRig.deadline,
         confirmTimeout: TimeInterval? = nil) async throws {
        fake = try FakeRightyo(script ?? FakeRightyo.ackingControl() + "\n" + AmbientPrivacyEntryTests.fixture(
            saying: words, enrolled: enrolled, advertises: advertises, version: version))
        try fake.install(fixture: enrolled ? "enrolled-formed-request.jsonl" : "tool-events.jsonl")
        let events = DuckEvents()
        env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: clips,
                                   replyControl: true, duckTimeout: timeout, startDeadline: startDeadline,
                                   ackDeadline: ackDeadline, confirmTimeout: confirmTimeout,
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
    /// Every event so far, as `name detail`, in order.
    func allEvents() -> [String] { events.list.withLock { $0.map { "\($0.event) \($0.detail ?? "")" } } }
    /// Waits until no new event has arrived for `quiet`, then returns them all.
    func settledEvents(quiet: Duration = .milliseconds(400)) async -> [String] {
        var last = allEvents()
        for _ in 0..<50 {
            try? await Task.sleep(for: quiet)
            let now = allEvents()
            if now == last { return now }
            last = now
        }
        return last
    }
    /// The connection the ambient stream belongs to, once the stream started.
    func connection() -> UUID? { events.list.withLock { $0.first { $0.event == "ambient_started" }?.sessionID } }

    /// The words of the next frame, which must be a confirmation's text.
    func confirmation() async throws -> String? {
        let frame = try await receiveFrame(on: socket, step: "confirmation words")
        guard case .text(let words) = frame.payload else { return nil }
        return words.text
    }

    /// Ends the stream, then waits for every run and stops the listener, each bounded (`within`) so a hang fails the
    /// test with a clear issue instead of blocking the run.
    func finish(within: Duration = .seconds(30)) async {
        try? await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await settle(within: within)
        await bounded("DuckRig listener stop", within: within) { [listener = env.listener] in
            await listener.stop(reason: "synthetic test complete")
        }
    }

    /// Every run returned, within `within`; otherwise an issue, never a hang.
    func settle(within: Duration = .seconds(30)) async {
        await boundedSettle(env.router, step: "DuckRig settle", within: within)
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
