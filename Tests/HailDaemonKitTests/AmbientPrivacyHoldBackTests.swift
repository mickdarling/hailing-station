#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The request-side hold-back of privacy mode's entry (#735 S-2 round 2), apart from the transcript side that usually
/// carries it out first. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyHoldBackTests {
    private func run(_ script: String) async throws -> ([PrivacyCommand], Int) {
        let fake = try FakeRightyo(script)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let seen = Mutex<[PrivacyCommand]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        (configuration.onVoiceDuck, configuration.replyControl) = ({ command in
            seen.withLock { $0.append(command) }
        }, true)
        let pipeline = try RightyoAmbientPipeline(configuration: configuration,
                                                  dispatcher: RecordingAmbientDispatcher())
        pipeline.finishInput()
        let delivered = try await pipeline.run().delivered
        return (seen.withLock { $0 }, delivered)
    }

    /// The request decides its own hold-back from its own heard text: here its transcript's match was evicted from the
    /// 32 remembered by 33 later matching transcripts, so only the request's own match holds it back (entry and
    /// negation alike) and carries it out once more. Nothing is typed.
    @Test(arguments: [("Rightyo, go private.", PrivacyCommand.enter),
                      ("Rightyo, do not stop recording.", .stillRecording)])
    func theRequestAloneHoldsItsPhraseBack(_ words: String, _ command: PrivacyCommand) async throws {
        let edit = #"-e "s/formed-demo/$7/g" -e 's/"phase": "started"/"duck": {"version": 2}, "phase": "started"/'"#
            + AmbientPrivacyEventTests.voiceprint
        let script = #"""
        /usr/bin/sed -n -e '1,5p' events.jsonl | /usr/bin/sed \#(edit) -e 's/Rightyo, archive the project./\#(words)/g'
        i=0
        while [ $i -lt 33 ]; do
          /usr/bin/sed -n -e '4p' events.jsonl | /usr/bin/sed \#(edit) \
            -e 's/Rightyo, archive the project./go private/g' -e "s/\"sequence\": 4/\"sequence\": $((i + 6))/" \
            -e "s/\"utterance_id\": \"request\"/\"utterance_id\": \"slip-$i\"/"
          i=$((i + 1))
        done
        /usr/bin/sed -n -e '6p' events.jsonl | /usr/bin/sed \#(edit) -e 's/Rightyo, archive the project./\#(words)/g' \
          -e 's/"sequence": 6/"sequence": 50/'
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" -e 's/"sequence": 7/"sequence": 99/'
        """#
        let (seen, delivered) = try await run(script)
        #expect(seen.count == 35 && seen.first == command && seen.last == command && delivered == 0)
    }

    /// Key 2's B1: while privacy is on, a transcript and its ignore attention that still arrive (the child has not
    /// read the line yet) reach no relay: nothing is shown as heard or overheard and nothing is acknowledged. With
    /// privacy off the same events are overheard, so the check is live.
    @Test(arguments: [true, false]) func whilePrivateNoWordsReachARelay(_ ducking: Bool) async throws {
        let duck = AmbientPrivacyEventTests.duck(2)
        let fake = try FakeRightyo(#"""
        /usr/bin/sed -n -e '1,3p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \#(duck)
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"
        """#)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let relayed = Mutex<[String]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            onAcknowledge: { _ in relayed.withLock { $0.append("ack") } }
        )
        configuration.onOverheard = { _, _, _ in relayed.withLock { $0.append("overheard") } }
        configuration.onHeard = { _ in relayed.withLock { $0.append("heard") } }
        (configuration.onVoiceDuck, configuration.replyControl) = ({ _ in }, true)
        let pipeline = try RightyoAmbientPipeline(configuration: configuration,
                                                  dispatcher: RecordingAmbientDispatcher())
        if ducking { pipeline.reportDuck(true) }
        pipeline.finishInput()
        _ = try await pipeline.run()
        #expect(relayed.withLock { $0 } == (ducking ? [] : ["overheard"]))
    }
}
#endif
