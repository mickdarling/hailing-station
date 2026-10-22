#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// RightyO's content-free `privacy` events (#735 S-2, rightyo S-1): `exit` and `status` reach the host only from a
/// session that advertised `duck` v2, carry `action` and nothing else, and never reach the agent. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyEventTests {
    /// One `privacy` line echoed by the fake, at `sequence` and `at` ms, with `extra` fields.
    static func line(_ action: String, sequence: Int, at: Int, extra: String = "") -> String {
        #"echo "{\"schema_version\": 1, \"type\": \"privacy\", \"session_id\": \"$7\", "#
            + #"\"sequence\": \#(sequence), \"emitted_at_ms\": \#(at)\#(extra), \"action\": \"\#(action)\"}""#
    }

    /// The owner's transcript attributed from a live voiceprint (`role_source`), the only one that may enter.
    static let voiceprint = #" -e '/"role": "owner"/s/"type": "transcript"/"#
        + #""role_source": "voiceprint", "type": "transcript"/'"#

    static func duck(_ version: Int) -> String {
        #" -e 's/"phase": "started"/"duck": {"version": \#(version)}, "phase": "started"/'"#
    }

    /// `started` (naming `Rightyo`, advertising `duck` at `version` unless nil), then one `privacy` event per action,
    /// each with `extra` fields, then `stopped`. No transcript and no request.
    static func events(_ actions: [String], version: Int? = 2, extra: String = "") -> String {
        let started = #"-e 's/"phase": "started"/"addressing": {"names": ["Rightyo"]}, "phase": "started"/'"#
            + (version.map(duck) ?? "")
        let lines = actions.enumerated().map { line($1, sequence: $0 + 2, at: 1000, extra: extra) }
        return """
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \(started)
        \(lines.joined(separator: "\n"))
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """
    }

    /// `started` (v2), the owner's transcript "Stop recording.", then one `privacy` event per action, then `stopped`.
    static func enterThen(_ actions: [String]) -> String {
        let lines = actions.enumerated().map { line($1, sequence: $0 + 5, at: 2000) }
        return """
        /usr/bin/sed -n -e '1p' -e '4p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/Rightyo, archive the project./Stop recording./g' \(duck(2))\(voiceprint)
        \(lines.joined(separator: "\n"))
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" -e 's/"sequence": 7/"sequence": 99/'
        """
    }

    private func run(_ script: String, ducking: Bool = true,
                     allowSynthetic: Bool = true) async throws -> ([PrivacyCommand], Int) {
        let fake = try FakeRightyo(script)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let seen = Mutex<[PrivacyCommand]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: allowSynthetic, timing: .init(eofGrace: 20, termGrace: 20)
        )
        configuration.onVoiceDuck = { command in seen.withLock { $0.append(command) } }
        configuration.replyControl = true
        let pipeline = try RightyoAmbientPipeline(configuration: configuration,
                                                  dispatcher: RecordingAmbientDispatcher())
        if ducking { pipeline.reportDuck(true) }
        pipeline.finishInput()
        let delivered = try await pipeline.run().delivered
        return (seen.withLock { $0 }, delivered)
    }

    @Test func exitAndStatusReachTheHostInOrder() async throws {
        let (seen, delivered) = try await run(Self.events(["status", "exit"]))
        #expect(seen == [.status, .exit] && delivered == 0)
    }

    @Test func aLaterVersionIsAdmittedToo() async throws {
        let (seen, _) = try await run(Self.events(["exit"], version: 3))
        #expect(seen == [.exit])
    }

    /// From a session that did not advertise `duck` v2 (v1 still transcribes, or none at all), a `privacy` event
    /// ends the stream, fail closed.
    @Test(arguments: [1, nil] as [Int?]) func withoutVersionTwoAPrivacyEventEndsTheStream(_ version: Int?) async {
        await #expect(throws: RightyoInputError.self) {
            _ = try await run(Self.events(["exit"], version: version), ducking: false)
        }
    }

    /// Content-free only: any field beyond `action`, or another action, ends the stream.
    @Test(arguments: [
        (["exit"], #", \"utterance_id\": \"request\""#), (["status"], #", \"reason\": \"timeout\""#),
        (["leave"], ""), (["exit"], #", \"duck\": {\"version\": 2}"#)
    ])
    func aPrivacyEventCarryingAnythingElseEndsTheStream(_ actions: [String], _ extra: String) async {
        await #expect(throws: RightyoInputError.self) { _ = try await run(Self.events(actions, extra: extra)) }
    }

    /// Only a live-microphone transcript enters (the fixture's turn is `synthetic`, with synthetic turns not admitted).
    @Test func aNonLiveTranscriptDoesNotEnter() async throws {
        let (live, _) = try await run(Self.enterThen([]), ducking: false)
        let (synthetic, _) = try await run(Self.enterThen([]), ducking: false, allowSynthetic: false)
        #expect(live == [.enter] && synthetic.isEmpty)
    }

    /// `privacy` refuses content in `validatePrivacy` itself: the same event, valid without them, is refused with a
    /// fully valid `turn` (words included) or a valid `utterance_id`.
    @Test func aPrivacyEventWithATurnOrUtteranceIsRefused() throws {
        let envelope = #""type": "privacy", "action": "exit", "schema_version": 1, "session_id": "s1", "#
            + #""sequence": 2, "emitted_at_ms": 5"#
        let turn = #""turn": {"session_id": "s1", "utterance_id": "u1", "revision": 1, "start_ms": 0, "end_ms": 5, "#
            + #""text": "hello there", "finalized": true, "overlap": false, "recognizer_id": "authored-fixture", "#
            + #""provenance": "synthetic", "speaker_provenance": "authored-fixture"}"#
        let bare = try RightyoInputEvent.decode(Data("{\(envelope)}".utf8))
        try bare.validate(session: "s1", enrolled: true)
        for extra in [turn, #""utterance_id": "u1""#] {
            let event = try RightyoInputEvent.decode(Data("{\(envelope), \(extra)}".utf8))
            #expect(throws: RightyoInputError.invalidEvent) { try event.validatePrivacy() }
            #expect(throws: RightyoInputError.invalidEvent) { try event.validate(session: "s1", enrolled: true) }
        }
    }

    @Test func theEventsSchemaKeepsActionAndDuckInTheirPlace() throws {
        let session = #""schema_version": 1, "session_id": "s1", "sequence": 2, "emitted_at_ms": 5"#
        let transcript = try RightyoInputEvent.decode(Data(#"{"type": "dismiss", "action": "exit", \#(session)}"#.utf8))
        #expect(throws: RightyoInputError.invalidEvent) { try transcript.validatePrivacy() }
        let ducked = try RightyoInputEvent.decode(Data(#"{"type": "privacy", "duck": {}, \#(session)}"#.utf8))
        #expect(throws: RightyoInputError.invalidEvent) { try ducked.validatePrivacy() }
        // `duck` outside `started`, and `role_source` off a transcript, are refused by `validatePrivacy` itself.
        for line in [#"{"type": "session", "phase": "stopped", "duck": {"version": 2}, \#(session)}"#,
                     #"{"type": "dismiss", "role_source": "voiceprint", \#(session)}"#] {
            let event = try RightyoInputEvent.decode(Data(line.utf8))
            #expect(throws: RightyoInputError.invalidEvent) { try event.validatePrivacy() }
        }
        let stopped = try RightyoInputEvent.decode(Data(#"{"type": "session", "phase": "stopped", \#(session)}"#.utf8))
        try stopped.validatePrivacy()
        #expect(RightyoInputEvent.privacyVersion(.object(["version": .integer(2)])) == 2)
        #expect(RightyoInputEvent.privacyVersion(.object(["version": .string("2")])) == nil)
        #expect(RightyoInputEvent.privacyVersion(.bool(true)) == nil)
    }
}

extension AmbientPrivacyEventTests {
    /// `started` advertising natural dismissal and `duck` at `version` unless nil, then a stop phrase's dismissal with
    /// `scope` and `ids` that cites no transcript, then `stopped`.
    static func privateStop(version: Int? = 2, scope: String = #"[\"playback\"]"#, ids: String = "[]") -> String {
        let dismissal = #""dismissal": {"version": 1, "window_ms": 10000, "cooldown_ms": 30000, "#
            + #""cooldown_min_confidence": 0.9}, "#
        let started = #"-e 's/"phase": "started"/\#(dismissal)"phase": "started"/'"# + (version.map(duck) ?? "")
        let stop = #"echo "{\"schema_version\": 1, \"type\": \"dismiss\", \"session_id\": \"$7\", \"sequence\": 2, "#
            + #"\"emitted_at_ms\": 1000, \"utterance_id\": \"private-1\", \"speech_end_ms\": 900, "#
            + #"\"role\": \"owner\", \"scope\": \#(scope), \"withdrawn_request_ids\": \#(ids), "#
            + #"\"reason\": \"stop-phrase\", \"confidence\": null}""#
        return """
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \(started)
        \(stop)
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """
    }

    private func dismissals(_ script: String) async throws -> [RightyoDismissReceipt] {
        let fake = try FakeRightyo(script)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let seen = Mutex<[RightyoDismissReceipt]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            onDismiss: { receipt in seen.withLock { $0.append(receipt) } }
        )
        (configuration.onVoiceDuck, configuration.replyControl) = ({ _ in }, true)
        let pipeline = try RightyoAmbientPipeline(configuration: configuration,
                                                  dispatcher: RecordingAmbientDispatcher())
        pipeline.reportDuck(true)
        pipeline.finishInput()
        _ = try await pipeline.run()
        return seen.withLock { $0 }
    }

    /// While private "stop" does nothing (Mick, round 2): RightyO sends no dismissal then, and an uncited one, even
    /// playback-only on a `duck` v2 session, ends the stream as it did before privacy mode.
    @Test(arguments: [
        (2, #"[\"playback\"]"#, "[]"), (2, #"[\"playback\", \"pending_request\"]"#, "[]"),
        (2, #"[\"playback\"]"#, #"[\"$7:x\"]"#), (1, #"[\"playback\"]"#, "[]")
    ])
    func anUncitedDismissalEndsTheStream(_ version: Int, _ scope: String, _ ids: String) async {
        let script = Self.privateStop(version: version, scope: scope, ids: ids)
        guard version >= 2 else {
            // A v1 child cannot keep the privacy wished for: refused at `started` (#735 S-2b), before any dismissal.
            await #expect(throws: RightyoPrivacyError.unconfirmed) { _ = try await dismissals(script) }
            return
        }
        await #expect(throws: RightyoInputError.self) { _ = try await dismissals(script) }
    }
}
#endif
