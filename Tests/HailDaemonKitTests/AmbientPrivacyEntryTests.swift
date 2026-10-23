#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Privacy mode's safety-set entry through the pipeline (#735 S-2): a standalone command, the live enrolled owner's
/// alone, held back from the agent, a negation answered "Still recording."; anyone else's is refused, the old duck
/// phrases are gone. The matcher's own table is `AmbientPrivacyCorpusTests`. Synthetic text only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyEntryTests {
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

    /// The live enrolled owner's entry enters once (from the transcript) and the request that carried it is held back.
    @Test func theOwnersEntryEntersAndItsRequestIsHeldBack() async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: "OK, um, Rightyo, stop recording."), enrolled: true)
        #expect(seen == [.enter] && delivered == 0)
    }

    /// Owner only (Mick, round 2): a guest's, an unlabelled turn's and an anonymous session's entry, negated or not, is
    /// `refused` (silent). The owner role without a live voiceprint (label-only, or no `role_source` as an inferred
    /// owner has none) is `unverified` (audible, round 3), though its negation, which changes nothing, is answered.
    /// Every one is held back.
    @Test(arguments: [
        ("guest", "Rightyo, stop recording.", PrivacyCommand.refused), ("unlabelled", "privacy mode", .refused),
        ("anonymous", "Rightyo, stop recording.", .refused), ("guest", "do not stop recording", .refused),
        ("label", "go private", .unverified), ("inferred", "Stop listening.", .unverified),
        ("label", "do not stop recording", .stillRecording)
    ])
    func anyoneElsesEntryIsRefusedAndHeldBack(_ who: String, _ words: String, _ command: PrivacyCommand) async throws {
        let script = Self.fixture(saying: words, enrolled: who != "anonymous", guest: who == "guest",
                                  unlabelled: who == "unlabelled",
                                  roleSource: who == "label" ? "label" : who == "inferred" ? nil : "voiceprint")
        let (seen, delivered) = try await run(script, enrolled: who != "anonymous")
        #expect(seen == [command] && delivered == 0)
    }

    /// The owner's bound label with an inferred word (RightyO `voiceprint_label`, #735; Mick: entry needs his voice)
    /// enters, as most short commands carry one; another speaker's turn carrying it is still refused, and an unknown
    /// source is no voiceprint (`unverified`).
    @Test(arguments: [
        ("owner", "voiceprint_label", PrivacyCommand.enter), ("guest", "voiceprint_label", .refused),
        ("owner", "voiceprint_guess", .unverified)
    ])
    func theOwnersBoundLabelEntersWithAnInferredWord(_ who: String, _ source: String,
                                                     _ command: PrivacyCommand) async throws {
        let script = Self.fixture(saying: "privacy mode", guest: who == "guest", roleSource: source)
        let (seen, delivered) = try await run(script, enrolled: true)
        #expect(seen == [command] && delivered == 0)
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

    /// Defence in depth: while private a stop-like turn that slips through is never an exit, and never typed.
    @Test(arguments: ["stop", "stop that", "stop listening", "Rightyo, stop."])
    func whilePrivateNoStopLikeTurnExits(_ words: String) async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: words, advertises: true), enrolled: true,
                                              ducking: true)
        #expect(!seen.contains(.exit) && delivered == 0)
    }

    /// An echo of the assistant's own words (a reply, or a clip such as "Privacy mode is off.") never enters from the
    /// transcript; its request is dropped as echo.
    @Test(arguments: ["Stop recording.", "Privacy mode is off.", "Privacy mode."])
    func anEchoedPhraseDoesNotEnter(_ words: String) async throws {
        let fake = try FakeRightyo(Self.fixture(saying: words))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let seen = Mutex<[PrivacyCommand]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            isEcho: { $0 == words }
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
    /// Sets `PRIV` to the `started` suffix that confirms privacy when the fake was launched `--start-private`.
    static let startPrivatePrelude = #"PRIV=''; case " $* " in *" --start-private "*) PRIV=', "private": true';; esac"#

    /// The voice-mute fixture with `words` said, the name `Rightyo` advertised, the owner's transcript attributed from
    /// a live voiceprint (`roleSource`, or none when nil), and optionally `duck` (`version`) advertised, every owner role
    /// turned into a guest's or removed, or the earlier turn made a lone "Rightyo,". Its control lines go to
    /// `control.txt` and each `{"duck":true}` is acked after its own lines (#735 S-8) with a `FakeRightyo.ackingControl`
    /// prefix.
    static func fixture(saying words: String, enrolled: Bool = true, guest: Bool = false, advertises: Bool = false,
                        version: Int = 3, splitName: Bool = false, unlabelled: Bool = false,
                        roleSource: String? = "voiceprint") -> String {
        let source = enrolled ? "Rightyo, archive the project." : "Rightyo, check our discussion."
        let session = enrolled ? "formed-demo" : "tool-demo"
        var edits = #"-e 's/"phase": "started"/"addressing": {"names": ["Rightyo"]}, "phase": "started"/'"#
        if advertises {
            // A child launched start-private (#735 S-2b) says so in `started`, as RightyO's round 2 does.
            edits += #" -e 's/"phase": "started"/"duck": {"version": \#(version)'"$PRIV"'}, "phase": "started"/'"#
        }
        if let roleSource, enrolled {
            edits += #" -e '/"role": "owner"/s/"type": "transcript"/"#
                + #""role_source": "\#(roleSource)", "type": "transcript"/'"#
        }
        if guest { edits += #" -e 's/"role": "owner"/"role": "participant"/g'"# }
        if unlabelled { edits += #" -e 's/, "role": "owner"//g' -e 's/"role": "owner", //g'"# }
        if splitName { edits += #" -e 's/"text": "Speaker A[^"]*"/"text": "Rightyo,"/g'"# }
        return """
        \(startPrivatePrelude)
        /usr/bin/sed -e '$d' -e "s/\(session)/$7/g" -e 's/\(source)/\(words)/g' \(edits) events.jsonl
        \(FakeRightyo.ackingTail)
        """
    }
}
#endif
