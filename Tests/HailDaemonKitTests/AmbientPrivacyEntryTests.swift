#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Privacy mode's safety-set entry (#735 S-2): matched locally and loosely, from any speaker, held back from the agent,
/// a negation answered "Still recording."; the old duck phrases are gone. Synthetic text only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyEntryTests {
    /// Each phrase, after filler, mid-turn, after a name, in any case and punctuation.
    @Test(arguments: [
        "Stop recording.", "stop listening", "Privacy mode", "go private", "STOP RECORDING!",
        "Jarvis, stop recording.", "Hey Rightyo, go private please", "OK, um, so stop listening",
        "Okay so, uh, privacy mode", "I think we should go private for a bit", "Can you stop-recording now?",
        "No, stop recording.", "Don't worry, stop recording", "Don’t stop. Stop recording.",
        "Don't stop recording. Actually, stop recording.", "Is privacy mode on?", "privacy mode on",
        "don't um stop recording"
    ])
    func anEntryPhraseAnywhereEnters(_ heard: String) {
        #expect(PrivacyEntry.match(heard) == .enter)
    }

    /// A negation right before the phrase, across a few bridging words, is held back as "Still recording.".
    @Test(arguments: [
        "Don't stop recording", "do not stop listening", "Please don’t go private.", "Jarvis, dont stop recording",
        "I don't want you to stop recording", "never stop listening", "We won't go private", "Do NOT privacy mode"
    ])
    func aNegatedPhraseIsStillRecording(_ heard: String) {
        #expect(PrivacyEntry.match(heard) == .negated)
    }

    /// Near misses, a request to leave privacy mode, a lone name and the old duck phrases are not entries.
    @Test(arguments: [
        "", "Jarvis,", "Jarvis", "stop", "recording", "privacy", "private mode", "go privately", "stop recordings",
        "the recording stopped", "listening to music", "privacy mode off", "end privacy mode", "turn off privacy mode",
        "get out of privacy mode", "Jarvis, duck mode.", "Let me think out loud", "Jarvis, done thinking."
    ])
    func anythingElseIsNoEntry(_ heard: String) {
        #expect(PrivacyEntry.match(heard) == nil)
    }

    /// A name said alone, then the phrase in the next turn: the phrase needs no name, so the second turn enters.
    @Test func aSplitNameStillEnters() {
        #expect(PrivacyEntry.match("Jarvis,") == nil && PrivacyEntry.match("stop recording") == .enter)
    }

    @Test func theControlLineReachesTheChild() async throws {
        let fake = try FakeRightyo("/bin/cat <&3 > control.txt")
        defer { fake.cleanUp() }
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config, session: "hail-test",
                                            timing: .init(eofGrace: 20, termGrace: 20), replyControl: true)
        #expect(child.reportDuck(true) && child.reportMedia(false) && child.reportDuck(false))
        #expect(await child.stop() == .exited(0))
        #expect(try fake.recorded("control.txt") == "{\"duck\":true}\n{\"media\":false}\n{\"duck\":false}\n")
    }

    /// Runs one fixture through a pipeline, with privacy already on when `ducking` (the fixture must then advertise
    /// `duck` v2), and returns what reached `onVoiceDuck` and how many requests were typed.
    private func run(_ script: String, enrolled: Bool, control: Bool = true, wired: Bool = true,
                     ducking: Bool = false) async throws -> ([PrivacyCommand], Int) {
        let fake = try FakeRightyo(script)
        defer { fake.cleanUp() }
        try fake.install(fixture: enrolled ? "enrolled-formed-request.jsonl" : "tool-events.jsonl")
        let seen = Mutex<[PrivacyCommand]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        if wired { configuration.onVoiceDuck = { command in seen.withLock { $0.append(command) } } }
        configuration.replyControl = control
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        if ducking { pipeline.reportDuck(true) }
        pipeline.finishInput()
        let delivered = try await pipeline.run().delivered
        return (seen.withLock { $0 }, delivered)
    }

    /// The owner's, a guest's and an anonymous session's entry each enter once (from the transcript) and the request
    /// that carried it is held back.
    @Test(arguments: [(true, false), (true, true), (false, false)])
    func anySpeakersEntryEntersAndItsRequestIsHeldBack(_ enrolled: Bool, _ guest: Bool) async throws {
        let script = Self.fixture(saying: "OK, um, Rightyo, stop recording.", enrolled: enrolled, guest: guest)
        let (seen, delivered) = try await run(script, enrolled: enrolled)
        #expect(seen == [.enter] && delivered == 0)
    }

    /// A lone name in one turn, then the phrase in the next.
    @Test func aSplitNameEntersFromTheSecondTurn() async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: "go private", splitName: true), enrolled: true)
        #expect(seen == [.enter] && delivered == 0)
    }

    @Test func aNegationIsStillRecordingAndNeverTyped() async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: "Rightyo, do not stop recording."), enrolled: true)
        #expect(seen == [.stillRecording] && delivered == 0)
    }

    /// The old duck phrases (#735 H-2) are ordinary requests now, and nothing is held.
    @Test(arguments: ["Rightyo, duck mode.", "Rightyo, let me think out loud.", "Rightyo, done thinking."])
    func theOldDuckPhrasesNoLongerAct(_ words: String) async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: words), enrolled: true)
        #expect(seen.isEmpty && delivered == 1)
    }

    /// Without a control descriptor the entry is still held back for the host, which refuses it: never typed.
    @Test func withoutControlTheEntryIsStillHeldBack() async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: "Stop listening."), enrolled: true, control: false)
        #expect(seen == [.enter] && delivered == 0)
    }

    /// Before the host handles privacy, the phrase is a request as before.
    @Test func withoutAHandlerThePhraseIsARequest() async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: "Stop listening."), enrolled: true, wired: false)
        #expect(seen.isEmpty && delivered == 1)
    }

    /// While private nothing reaches the agent: a request already in flight is dropped, unannounced.
    @Test func whilePrivateARequestInFlightIsDropped() async throws {
        let script = Self.fixture(saying: "Rightyo, archive the project.", advertises: true)
        let (seen, delivered) = try await run(script, enrolled: true, ducking: true)
        #expect(seen.isEmpty && delivered == 0)
    }

    /// An echo of the assistant's own words never enters from the transcript; its request is dropped as echo.
    @Test func anEchoedPhraseDoesNotEnter() async throws {
        let fake = try FakeRightyo(Self.fixture(saying: "I can stop recording if you like."))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let seen = Mutex<[PrivacyCommand]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            isEcho: { $0.contains("stop recording") }
        )
        (configuration.onVoiceDuck, configuration.replyControl) = ({ command in
            seen.withLock { $0.append(command) }
        }, true)
        let pipeline = try RightyoAmbientPipeline(configuration: configuration,
                                                  dispatcher: RecordingAmbientDispatcher())
        pipeline.finishInput()
        #expect(try await pipeline.run().delivered == 0)
        #expect(seen.withLock { $0 }.isEmpty)
    }
}

extension AmbientPrivacyEntryTests {
    /// The voice-mute fixture with `words` said, the name `Rightyo` advertised, and optionally `duck` (`version`)
    /// advertised, every owner role turned into a guest's, or the earlier turn made a lone "Rightyo,".
    static func fixture(saying words: String, enrolled: Bool = true, guest: Bool = false, advertises: Bool = false,
                        version: Int = 2, splitName: Bool = false) -> String {
        let source = enrolled ? "Rightyo, archive the project." : "Rightyo, check our discussion."
        let session = enrolled ? "formed-demo" : "tool-demo"
        var edits = #"-e 's/"phase": "started"/"addressing": {"names": ["Rightyo"]}, "phase": "started"/'"#
        if advertises {
            edits += #" -e 's/"phase": "started"/"duck": {"version": \#(version)}, "phase": "started"/'"#
        }
        if guest { edits += #" -e 's/"role": "owner"/"role": "participant"/g'"# }
        if splitName { edits += #" -e 's/"text": "Speaker A[^"]*"/"text": "Rightyo,"/g'"# }
        return """
        /usr/bin/sed -e '$d' -e "s/\(session)/$7/g" -e 's/\(source)/\(words)/g' \(edits) events.jsonl
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/\(session)/$7/g"
        """
    }
}
#endif
