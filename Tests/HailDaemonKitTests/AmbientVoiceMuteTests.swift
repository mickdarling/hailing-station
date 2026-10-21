#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken "mute" and "unmute" (#404): carried out by the host on the device that said it, never typed to
/// the agent. Synthetic only; not device hearing.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringVoiceMuteTests {
    static let muted = AmbientAckClip(pcm: Data(repeating: 4, count: 480), sampleRate: 24_000, text: "Muted.")
    static let unmuted = AmbientAckClip(pcm: Data(repeating: 5, count: 480), sampleRate: 24_000, text: "Unmuted.")

    /// The tool fixture with its request (and the turn it cites) saying `words` instead, and, when `named`, its
    /// `started` advertising "Rightyo" as an addressing name.
    static func fixture(saying words: String, enrolled: Bool = false, named: Bool = true) -> String {
        let source = enrolled ? "Rightyo, archive the project." : "Rightyo, check our discussion."
        let session = enrolled ? "formed-demo" : "tool-demo"
        let name = named ? #"-e 's/"phase": "started"/"addressing": {"names": ["Rightyo"]}, "phase": "started"/'"# : ""
        return """
        /usr/bin/sed -e '$d' -e "s/\(session)/$7/g" -e 's/\(source)/\(words)/g' \(name) events.jsonl
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

    @Test func aNameTheSessionDidNotAdvertiseMakesItARequest() async throws {
        let fake = try FakeRightyo(Self.fixture(saying: "Rightyo, mute.", named: false))
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let mutes = Mutex<[Bool]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        configuration.onVoiceMute = { value in mutes.withLock { $0.append(value) } }
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        pipeline.finishInput()
        #expect(try await pipeline.run().delivered == 1)
        #expect(mutes.withLock { $0 }.isEmpty)
    }

    /// `participant` demotes the turn and its attention record; `decision` only the record, which the consumer's
    /// fail-closed owner check then refuses as the owner's.
    @Test(arguments: [("owner", 0, [true]), ("participant", 1, [Bool]()), ("decision", 1, [Bool]())])
    func onAnEnrolledSessionOnlyTheOwnersMuteCounts(_ role: String, _ delivered: Int, _ mutes: [Bool]) async throws {
        var fixture = Self.fixture(saying: "Rightyo, mute.", enrolled: true)
        let demote = switch role {
        case "participant": #"-e 's/"role": "owner"/"role": "participant"/g'"#
        case "decision": #"-e 's/"system", "role": "owner"/"system", "role": "participant"/'"#
        default: ""
        }
        let first = "events.jsonl\n/bin/cat"
        fixture = fixture.replacingOccurrences(of: first, with: "\(demote) \(first)")
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
            // On the wire the clip's final audio frame precedes the mute, so the device is playing it when the mute
            // arrives and applies the mute after it, not at once over a silent clip.
            let clip = try await receiveFrame(on: socket, step: "confirmation clip")
            guard case .audio(let audio) = clip.payload else {
                Issue.record("expected the clip before the mute")
                return
            }
            #expect(audio.isFinal && audio.bytes == Self.muted.pcm && audio.reply == words.reply)
            #expect(try await receiveFrame(on: socket, step: "mute").payload == .control(.setReplyMute(muted: true)))
        }
        #expect(details == ["muted=true mute=sent playback=stopped confirm=confirmmuted/0:sent"])
    }

    @Test func anUnmuteIsSentBeforeUnmutedIsSpoken() async throws {
        let caps = [PlaybackStop.capability, ReplyMute.capability]
        let details = try await run(saying: "Rightyo, you can talk again.", capabilities: caps) { socket in
            let unmute = try await receiveFrame(on: socket, step: "unmute").payload
            #expect(unmute == .control(.setReplyMute(muted: false)))
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

#endif
