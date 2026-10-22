#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken duck mode (#735 H-2): recognised by the host only when it names the assistant, carried out only
/// for the enrolled owner, refused on an anonymous session, never typed to the agent. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceDuckTests {
    static let names: Set<String> = ["jarvis", "rightyo"]

    @Test(arguments: [
        ("Jarvis, duck mode.", VoiceDuckCommand.on), ("Hey Jarvis, let me think out loud", .on),
        ("Jarvis, duck mode please", .on), ("Okay Righty O, please let me think out loud.", .on),
        ("Jarvis, done thinking.", .off), ("Jarvis, I'm done thinking, please.", .off),
        ("Hey Jarvis, end duck mode", .off)
    ])
    func aNamedWholeTurnDuckPhraseIsRecognised(_ heard: String, _ command: VoiceDuckCommand) {
        #expect(VoiceDuck.command(in: heard, names: Self.names) == command)
    }

    /// Unnamed phrases never count, for entry or exit, nor do longer turns, negations or another assistant's name.
    @Test(arguments: [
        "Duck mode.", "Let me think out loud", "Hey, done thinking", "Please duck mode",
        "Jarvis, don't start duck mode", "Siri, duck mode", "Jarvis, let me think out loud about the duck pond",
        "Jarvis", "", "Jarvis, mute.", "Jarvis, media mode"
    ])
    func anythingElseIsNotADuckCommand(_ heard: String) {
        #expect(VoiceDuck.command(in: heard, names: Self.names) == nil)
    }

    @Test func noAdvertisedNameMeansNoDuckPhrase() {
        #expect(VoiceDuck.command(in: "Jarvis, duck mode.", names: []) == nil)
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

    /// Runs one fixture through a pipeline and returns what reached `onVoiceDuck` and how many requests were typed.
    private func run(_ script: String, enrolled: Bool, control: Bool = true, wired: Bool = true)
        async throws -> ([VoiceDuckCommand], Int) {
        let fake = try FakeRightyo(script)
        defer { fake.cleanUp() }
        try fake.install(fixture: enrolled ? "enrolled-formed-request.jsonl" : "tool-events.jsonl")
        let seen = Mutex<[VoiceDuckCommand]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        if wired { configuration.onVoiceDuck = { command in seen.withLock { $0.append(command) } } }
        configuration.replyControl = control
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        pipeline.finishInput()
        let delivered = try await pipeline.run().delivered
        return (seen.withLock { $0 }, delivered)
    }

    @Test func theEnrolledOwnersEntryIsHandedToTheHostNotTyped() async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: "Rightyo, duck mode."), enrolled: true)
        #expect(seen == [.on] && delivered == 0)
    }

    /// The exit is carried out from the owner's transcript (in duck mode RightyO sends no request), and the request
    /// that follows it here is held back without a second off.
    @Test func theOwnersExitIsCarriedOutOnceFromItsTranscript() async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: "Rightyo, done thinking."), enrolled: true)
        #expect(seen == [.off] && delivered == 0)
    }

    @Test func onAnAnonymousSessionTheEntryIsRefusedNotTyped() async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: "Rightyo, duck mode.", enrolled: false),
                                              enrolled: false)
        #expect(seen == [.refused] && delivered == 0)
    }

    /// A guest's phrase on an enrolled session is a request like any other, as for spoken notes (#552).
    @Test(arguments: ["Rightyo, duck mode.", "Rightyo, done thinking."])
    func aGuestsPhraseIsARequestLikeAnyOther(_ words: String) async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: words, guest: true), enrolled: true)
        #expect(seen.isEmpty && delivered == 1)
    }

    /// Without a control descriptor, or before the host handles duck mode, the phrase is a request as before.
    @Test(arguments: [(false, true), (true, false)])
    func withoutControlOrAHandlerThePhraseIsARequest(_ control: Bool, _ wired: Bool) async throws {
        let (seen, delivered) = try await run(Self.fixture(saying: "Rightyo, duck mode."), enrolled: true,
                                              control: control, wired: wired)
        #expect(seen.isEmpty && delivered == 1)
    }
}

extension AmbientVoiceDuckTests {
    /// The voice-mute fixture with `words` said, the name `Rightyo` advertised, and optionally the `duck` capability
    /// (rightyo R-2) advertised or every owner role turned into a guest's.
    static func fixture(saying words: String, enrolled: Bool = true, guest: Bool = false,
                        advertises: Bool = false) -> String {
        let source = enrolled ? "Rightyo, archive the project." : "Rightyo, check our discussion."
        let session = enrolled ? "formed-demo" : "tool-demo"
        var edits = #"-e 's/"phase": "started"/"addressing": {"names": ["Rightyo"]}, "phase": "started"/'"#
        if advertises { edits += #" -e 's/"phase": "started"/"duck": {"version": 1}, "phase": "started"/'"# }
        if guest { edits += #" -e 's/"role": "owner"/"role": "participant"/g'"# }
        return """
        /usr/bin/sed -e '$d' -e "s/\(session)/$7/g" -e 's/\(source)/\(words)/g' \(edits) events.jsonl
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/\(session)/$7/g"
        """
    }
}
#endif
