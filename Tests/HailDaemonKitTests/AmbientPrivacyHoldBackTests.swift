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
        let script = Self.evicted(saying: words)
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

    /// Key 1's M13: the request path's own owner gate, with the transcript's match evicted. A guest's request is
    /// refused (silent), the owner role's without a voiceprint `unverified` (audible), and neither enters or is typed.
    @Test(arguments: [(true, true, PrivacyCommand.refused), (false, false, .unverified)])
    func theRequestPathGatesTheOwner(_ guest: Bool, _ voiceprint: Bool, _ command: PrivacyCommand) async throws {
        let (seen, delivered) = try await run(Self.evicted(saying: "Rightyo, go private.", guest: guest,
                                                           voiceprint: voiceprint))
        #expect(seen.count == 35 && Set(seen) == [command] && delivered == 0)
    }

    /// Round 3 B3(b): the owner's turn that starts with a command and goes on is held back with a hint; a guest's is an
    /// ordinary request, since only the owner's commands count.
    @Test(arguments: [false, true]) func theOwnersPartialCommandIsHeldWithAHint(_ guest: Bool) async throws {
        let script = AmbientPrivacyEntryTests.fixture(saying: "Rightyo, stop recording the meeting.", guest: guest)
        let (seen, delivered) = try await run(script)
        #expect(seen == (guest ? [] : [.hint]) && delivered == (guest ? 1 : 0))
    }

    /// Key 2's M8: on the request path the owner must be the owner in both records. Here the transcript (owner, from a
    /// voiceprint) enters, its match is then evicted, and the attention demoted the turn: the request alone is refused.
    @Test func aDemotedOwnersRequestIsRefused() async throws {
        let (seen, delivered) = try await run(Self.evicted(saying: "Rightyo, go private.", demoted: true))
        #expect(seen.count == 35 && seen.first == .enter && seen.last == .refused && delivered == 0)
    }

    /// Key 2's M12: a transcript heard before privacy, whose attention arrives once privacy is on (the owner's entry
    /// came between), is never overheard. Without the entry the same transcript is.
    @Test(arguments: [true, false]) func anAttentionArrivingWhilePrivateIsNotOverheard(_ entry: Bool) async throws {
        let words = entry ? "Stop recording." : "Rightyo, archive the project."
        let duck = AmbientPrivacyEventTests.duck(2) + AmbientPrivacyEventTests.voiceprint
        let fake = try FakeRightyo(#"""
        /usr/bin/sed -n -e '1,2p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \#(duck)
        /usr/bin/sed -n -e '4p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \#(duck) \
          -e 's/Rightyo, archive the project./\#(words)/g'
        /usr/bin/sed -n -e '3p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/"sequence": 3/"sequence": 5/' -e 's/"emitted_at_ms": 500/"emitted_at_ms": 2000/'
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" -e 's/"sequence": 7/"sequence": 9/'
        """#)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let overheard = Mutex(0), box = Mutex<RightyoAmbientPipeline?>(nil)
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        configuration.onOverheard = { _, _, _ in overheard.withLock { $0 += 1 } }
        (configuration.onVoiceDuck, configuration.replyControl) = ({ command in
            if command == .enter { box.withLock { $0 }?.reportDuck(true) }
        }, true)
        let pipeline = try RightyoAmbientPipeline(configuration: configuration,
                                                  dispatcher: RecordingAmbientDispatcher())
        box.withLock { $0 = pipeline }
        pipeline.finishInput()
        _ = try await pipeline.run()
        box.withLock { $0 = nil }
        #expect(overheard.withLock { $0 } == (entry ? 0 : 1))
    }

    /// `started` (v2), the owner's transcript of `words` (from a voiceprint) and its attention, then 33 matching
    /// transcripts that evict it from the 32 remembered, then its request (with both decisions demoted when `demoted`).
    static func evicted(saying words: String, demoted: Bool = false, guest: Bool = false,
                        voiceprint: Bool = true) -> String {
        let edit = #"-e "s/formed-demo/$7/g" -e 's/"phase": "started"/"duck": {"version": 2}, "phase": "started"/'"#
            + (voiceprint ? AmbientPrivacyEventTests.voiceprint : "")
            + (guest ? #" -e 's/"role": "owner"/"role": "participant"/g'"# : "")
            + (demoted ? #" -e 's/"recipient_kind": "system", "role": "owner"/"#
                + #""recipient_kind": "system", "role": "participant"/'"# : "")
        return #"""
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
    }
}
#endif
