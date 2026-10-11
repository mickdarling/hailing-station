#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken "mute" and "unmute" (#404): carried out by the host on the device that said it, never typed to
/// the agent. Synthetic only; not device hearing.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientVoiceMuteTests {
    static let muted = AmbientAckClip(pcm: Data(repeating: 4, count: 480), sampleRate: 24_000, text: "Muted.")
    static let unmuted = AmbientAckClip(pcm: Data(repeating: 5, count: 480), sampleRate: 24_000, text: "Unmuted.")

    @Test(arguments: [
        ("Jarvis, mute.", true), ("mute", true), ("Hey Jarvis, go quiet please.", true), ("Text only.", true),
        ("Jarvis please mute", true), ("Jarvis, unmute.", false), ("You can talk again.", false),
        ("Friday, talk again", false)
    ])
    func aWholeTurnMutePhraseIsRecognised(_ heard: String, _ muted: Bool) {
        #expect(VoiceMute.command(in: heard) == (muted ? .mute : .unmute))
    }

    @Test(arguments: [
        "Don't mute.", "Jarvis, don't mute.", "Mute the TV in the other room.", "Can you mute", "Is it muted?",
        "Jarvis, mute the meeting notes", "", "Jarvis", "Not text only", "Okay, so then mute"
    ])
    func anythingElseIsNotAMute(_ heard: String) {
        #expect(VoiceMute.command(in: heard) == nil)
    }

    /// The tool fixture with its request (and the turn it cites) saying `words` instead.
    static func fixture(saying words: String, enrolled: Bool = false) -> String {
        let source = enrolled ? "Rightyo, archive the project." : "Rightyo, check our discussion."
        let session = enrolled ? "formed-demo" : "tool-demo"
        return """
        /usr/bin/sed -e '$d' -e "s/\(session)/$7/g" -e 's/\(source)/\(words)/g' events.jsonl
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/\(session)/$7/g"
        """
    }

    @Test(arguments: [("Rightyo, mute.", true), ("Rightyo, you can talk again.", false)])
    func aSpokenMuteIsHandedToTheHostNotTypedShownOrAcknowledged(_ words: String, _ muted: Bool) async throws {
        let fake = try FakeRightyo(Self.fixture(saying: words))
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let mutes = Mutex<[Bool]>([]), acks = Mutex(0), heard = Mutex(0)
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            onAcknowledge: { _ in acks.withLock { $0 += 1 } }
        )
        configuration.onVoiceMute = { value in mutes.withLock { $0.append(value) } }
        configuration.onHeard = { _ in heard.withLock { $0 += 1 } }
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        pipeline.finishInput()
        #expect(try await pipeline.run().delivered == 0)
        #expect(mutes.withLock { $0 } == [muted])
        #expect(acks.withLock { $0 } == 0 && heard.withLock { $0 } == 0)
    }

    @Test(arguments: [("owner", 0, [true]), ("participant", 1, [Bool]())])
    func onAnEnrolledSessionOnlyTheOwnersMuteCounts(_ role: String, _ delivered: Int, _ mutes: [Bool]) async throws {
        var fixture = Self.fixture(saying: "Rightyo, mute.", enrolled: true)
        if role != "owner" {
            let demote = "-e 's/\"role\": \"owner\"/\"role\": \"participant\"/g'"
            let first = "events.jsonl\n/bin/cat"
            fixture = fixture.replacingOccurrences(of: first, with: "\(demote) \(first)")
        }
        let fake = try FakeRightyo(fixture)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let seen = Mutex<[Bool]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        configuration.onVoiceMute = { value in seen.withLock { $0.append(value) } }
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        pipeline.finishInput()
        #expect(try await pipeline.run().delivered == delivered)
        #expect(seen.withLock { $0 } == mutes)
    }

    @Test func aCapableDeviceIsStoppedThenHearsMutedThenIsMuted() async throws {
        let caps = [PlaybackStop.capability, ReplyMute.capability]
        let details = try await run(saying: "Rightyo, mute.", capabilities: caps) { socket in
            #expect(try await receiveFrame(on: socket, step: "stop").payload == .control(.stopPlayback))
            let text = try await receiveFrame(on: socket, step: "confirmation words")
            guard case .text(let words) = text.payload else {
                Issue.record("expected the confirmation")
                return
            }
            #expect(words.text == "Muted.")
            _ = try await receiveFrame(on: socket, step: "confirmation clip")
            #expect(try await receiveFrame(on: socket, step: "mute").payload == .control(.setReplyMute(muted: true)))
        }
        #expect(details == ["muted=true mute=sent playback=stopped confirm=confirmmuted/0:sent"])
    }

    @Test func anUnmuteIsSentBeforeUnmutedIsSpoken() async throws {
        let caps = [PlaybackStop.capability, ReplyMute.capability]
        let details = try await run(saying: "Rightyo, you can talk again.", capabilities: caps) { socket in
            #expect(try await receiveFrame(on: socket, step: "unmute").payload
                == .control(.setReplyMute(muted: false)))
            let text = try await receiveFrame(on: socket, step: "confirmation words")
            guard case .text(let words) = text.payload else {
                Issue.record("expected the confirmation")
                return
            }
            #expect(words.text == "Unmuted.")
            _ = try await receiveFrame(on: socket, step: "confirmation clip")
        }
        #expect(details == ["muted=false mute=sent playback=none confirm=confirmunmuted/0:sent"])
    }

    @Test func anOlderDeviceIsOnlyStoppedAndHearsStopped() async throws {
        let details = try await run(saying: "Rightyo, mute.", capabilities: [PlaybackStop.capability]) { socket in
            #expect(try await receiveFrame(on: socket, step: "stop").payload == .control(.stopPlayback))
            let text = try await receiveFrame(on: socket, step: "confirmation words")
            guard case .text(let words) = text.payload else {
                Issue.record("expected the confirmation")
                return
            }
            #expect(words.text == "Stopped.")
            _ = try await receiveFrame(on: socket, step: "confirmation clip")
            try await recipientSocketBarrier(on: socket) // and no set_reply_mute after it
        }
        #expect(details == ["muted=true mute=unsupported playback=stopped confirm=confirmstopped/0:sent"])
    }
}

/// The listener rig, kept outside the suite's body so it stays within the type-length limit.
extension AmbientVoiceMuteTests {
    /// One ambient stream whose request says `saying`, with confirmation clips loaded, from a device advertising
    /// `capabilities`; waits for the `ambient_voice_mute` line, runs `check`, then returns every such detail.
    private func run(
        saying words: String, capabilities: [String], check: (URLSessionWebSocketTask) async throws -> Void
    ) async throws -> [String] {
        let fake = try FakeRightyo(Self.fixture(saying: words))
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let details = Mutex<[String]>([])
        let library = AmbientAckLibrary(clips: [
            "confirmstopped": [AmbientStopConfirmationTests.stopped], "confirmmuted": [Self.muted],
            "confirmunmuted": [Self.unmuted]
        ])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: library,
            onEvent: { event in
                if event.event == "ambient_voice_mute" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let (session, socket) = try recipientSocket(port: env.port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: capabilities, deviceName: "test"
        )))), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await recipientSocketBarrier(on: socket)
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: socket)
        #expect(await eventually { details.withLock { !$0.isEmpty } })
        try await check(socket)
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        return details.withLock { $0 }
    }
}
#endif
