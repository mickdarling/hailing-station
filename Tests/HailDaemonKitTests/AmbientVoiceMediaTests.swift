#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken media mode (#551): recognised by the host, never typed to the agent, sent to RightyO over the
/// control descriptor (rightyo#195), and turned off again by voice or by its timeout. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientVoiceMediaTests {
    static let names: Set<String> = ["jarvis", "rightyo"]
    static let mediaOn = AmbientAckClip(pcm: Data(repeating: 6, count: 480), sampleRate: 24_000,
                                        text: "Media mode on.")

    @Test(arguments: [
        ("Jarvis, media mode.", true), ("I'm going to watch TV.", true), ("Hey Jarvis, watching TV", true),
        ("Jarvis, putting a video on please", true), ("Jarvis, media mode off.", false),
        ("Jarvis, I'm done watching.", false), ("The TV's off.", false)
    ])
    func aWholeTurnMediaPhraseIsRecognised(_ heard: String, _ on: Bool) {
        #expect(VoiceMedia.command(in: heard, names: Self.names) == (on ? .on : .off))
    }

    @Test(arguments: [
        "I'm watching TV with my sister", "Don't turn on media mode", "Siri, media mode", "What's on TV?",
        "Jarvis, mute.", "", "Jarvis"
    ])
    func anythingElseIsNotAMediaCommand(_ heard: String) {
        #expect(VoiceMedia.command(in: heard, names: Self.names) == nil)
    }

    @Test func theControlLineReachesTheChild() async throws {
        let fake = try FakeRightyo("/bin/cat <&3 > control.txt")
        defer { fake.cleanUp() }
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config, session: "hail-test",
                                            timing: .init(eofGrace: 20, termGrace: 20), replyControl: true)
        #expect(child.reportMedia(true) && child.reportReply(.started) && child.reportMedia(false))
        #expect(await child.stop() == .exited(0))
        #expect(try fake.recorded("control.txt") == "{\"media\":true}\n{\"reply\":\"started\"}\n{\"media\":false}\n")
    }

    /// Only with reply control, whose descriptor carries the mode to RightyO; without it the phrase is a request.
    @Test(arguments: [true, false]) func aSpokenMediaCommandIsHandedToTheHostNotTyped(_ control: Bool) async throws {
        let fake = try FakeRightyo(AmbientWiringVoiceMuteTests.fixture(saying: "Rightyo, media mode."))
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let seen = Mutex<[Bool]>([]), mutes = Mutex(0)
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        configuration.onVoiceMedia = { on in seen.withLock { $0.append(on) } }
        configuration.onVoiceMute = { _ in mutes.withLock { $0 += 1 } }
        configuration.replyControl = control
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        pipeline.finishInput()
        #expect(try await pipeline.run().delivered == (control ? 0 : 1))
        #expect(seen.withLock { $0 } == (control ? [true] : []) && mutes.withLock { $0 } == 0)
    }

    /// End to end through the listener: the phrase turns media mode on in the stream's child and is confirmed on the
    /// device that said it; the timeout then turns it off in the same child.
    @Test func mediaModeReachesTheChildIsConfirmedAndTimesOut() async throws {
        let fake = try FakeRightyo("/bin/cat <&3 > control.txt &\n"
            + AmbientWiringVoiceMuteTests.fixture(saying: "Rightyo, media mode."))
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let details = Mutex<[String]>([])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20),
            acknowledgements: AmbientAckLibrary(clips: ["confirmmediaon": [Self.mediaOn]]), replyControl: true,
            mediaTimeout: 0.5,
            onEvent: { event in
                if event.event == "ambient_media" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let (session, socket) = try recipientSocket(port: env.port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: [], deviceName: "test"
        )))), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await recipientSocketBarrier(on: socket)
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: socket)
        let text = try await receiveFrame(on: socket, step: "confirmation words")
        guard case .text(let words) = text.payload else {
            Issue.record("expected the confirmation")
            return
        }
        #expect(words.text == "Media mode on.")
        #expect(await eventually { details.withLock { $0.count == 2 } })
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        #expect(details.withLock { $0 } == ["on=true reason=voice reported=1", "on=false reason=timeout reported=1"])
        #expect(try fake.recorded("control.txt") == "{\"media\":true}\n{\"media\":false}\n")
    }

    /// A child reloaded while media mode is on is told at registration, before anything it hears is decided.
    @Test func aReloadedChildIsToldMediaModeIsOn() async throws {
        let fake = try FakeRightyo("/bin/cat <&3 >> control.txt &\n"
            + AmbientWiringVoiceMuteTests.fixture(saying: "Rightyo, media mode."))
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let details = Mutex<[String]>([])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20), replyControl: true,
            onEvent: { event in
                if event.event == "ambient_media" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let (session, socket) = try recipientSocket(port: env.port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: [], deviceName: "test"
        )))), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await recipientSocketBarrier(on: socket)
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: socket)
        #expect(await eventually { details.withLock { $0.count == 1 } })
        #expect(await env.router.reload() == .reloaded)
        // The old child's line, the new child's carried line, then the new child's own replayed phrase.
        let three = String(repeating: "{\"media\":true}\n", count: 3)
        #expect(await eventually { (try? fake.recorded("control.txt")) == three })
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
    }
}
#endif
