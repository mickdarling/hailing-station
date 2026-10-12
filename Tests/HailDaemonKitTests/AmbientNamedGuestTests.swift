#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Named guests (#434): an overheard turn by an enrolled guest RightyO bound (rightyo#171) carries their display name
/// to a device that can show it; anything uncertain, invalid or the owner's stays unnamed. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientNamedGuestTests {
    @Test(arguments: ["Ben", "Zoë", "李雷", "Ben O'Neil", "José-María", "R2-D2", "Ben 🎸"])
    func aPrintableNameIsShown(_ name: String) {
        #expect(AmbientOverheardRelay.guestName(.string(name)) == name)
    }

    /// ZWJ and ZWNJ names fail the protocol's rule and fall back; so does anything invisible or out of bounds.
    @Test(arguments: [
        "Ben\u{200D}", "\u{0645}\u{06CC}\u{200C}\u{0634}\u{0648}\u{062F}", "👨‍👩‍👧", "\u{3164}", "\u{3164}\u{3164}",
        "\u{2800}", "\u{FE0F}", "\u{0301}\u{0301}", "Ben\u{202E}", "Ben\u{00AD}", " Ben", "Ben ", "", "Ben\nSmith",
        String(repeating: "B", count: AmbientOverheard.maxNameScalars + 1)
    ])
    func anythingElseFallsBackToSomeone(_ name: String) {
        #expect(AmbientOverheardRelay.guestName(.string(name)) == nil)
    }

    @Test func aNonStringOrAbsentNameFallsBack() {
        #expect(AmbientOverheardRelay.guestName(.integer(1)) == nil)
        #expect(AmbientOverheardRelay.guestName(.null) == nil)
        #expect(AmbientOverheardRelay.guestName(nil) == nil)
    }

    private static func line(_ fields: String, sequence: Int) throws -> RightyoInputEvent {
        let prefix = #"{"schema_version": 1, "session_id": "s", "sequence": \#(sequence), "emitted_at_ms": 0, "#
        return try RightyoInputEvent.decode(Data((prefix + fields + "}").utf8))
    }

    private static func started(advertising: Bool) throws -> RightyoInputEvent {
        let names = advertising ? #""speaker_names": {"max_scalars": 64}, "# : ""
        return try line(#"""
            "type": "session", "phase": "started", \#(names)"capabilities": {"activation": "finalized-turn",
             "partials": false, "speakers": "enrolled", "context": true}
            """#, sequence: 1)
    }

    private static func turn(_ id: String, name: String?, role: String) throws -> [RightyoInputEvent] {
        let named = name.map { #""speaker_name": "\#($0)", "# } ?? ""
        return [
            try line(#"""
                "type": "transcript", \#(named)"turn": {"session_id": "s", "utterance_id": "\#(id)", "revision": 1,
                 "start_ms": 0, "end_ms": 500, "text": "Sounds good.", "finalized": true, "overlap": false,
                 "recognizer_id": "r", "provenance": "live-microphone", "speaker_provenance": "diarization-timeline",
                 "role": "\#(role)"}
                """#, sequence: 2),
            try line(#"""
                "type": "attention", "utterance_id": "\#(id)", "speech_end_ms": 500,
                 "decision": {"label": "ignore", "recipient_kind": "other_human", "confidence": 1.0,
                  "provider": "mock", "model": "m", "role": "\#(role)"}
                """#, sequence: 3)
        ]
    }

    /// Who the relay reports each turn as: the owner, a guest's name, or "other".
    private func reported(advertising: Bool, _ turns: [(name: String?, role: String)]) async throws -> [String] {
        let seen = AmbientOverheardTests.Seen()
        let relay = AmbientOverheardRelay(
            onOverheard: { _, owner, name in seen.append(owner ? "owner" : name ?? "other") }, isEcho: nil
        )
        await relay.observe(try Self.started(advertising: advertising))
        for (index, turn) in turns.enumerated() {
            for event in try Self.turn("u\(index)", name: turn.name, role: turn.role) { await relay.observe(event) }
        }
        return seen.all
    }

    @Test func aBoundGuestIsNamedOnlyOnASessionThatAdvertisedNames() async throws {
        let turns: [(name: String?, role: String)] = [
            ("Ben", "participant"), ("Ben", "trusted"), (nil, "participant"), ("Ben", "owner"), (" Ben", "unknown")
        ]
        #expect(try await reported(advertising: true, turns) == ["Ben", "Ben", "other", "owner", "other"])
        #expect(try await reported(advertising: false, turns) == ["other", "other", "other", "owner", "other"])
    }

    /// The tool fixture with `speaker_names` advertised and its ignored remark bound to "Ben".
    static let namedFixture = """
        /usr/bin/sed -e '$d' -e "s/tool-demo/$7/g" \
          -e 's/"phase": "started",/"speaker_names": {"max_scalars": 64}, "phase": "started",/' \
          -e '2s/^{/{"speaker_name": "Ben", /' events.jsonl
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        """

    /// Through the real listener: a device that advertised `ambient_overheard_names` sees "Ben"; an older one gets the
    /// same turn unnamed, never a key it would refuse. The relay sees only lines the consumer admitted, so this also
    /// shows a transcript carrying `speaker_name` (beside its turn, fingerprints unchanged) is admitted.
    @Test(arguments: [true, false])
    func onlyADeviceThatCanShowNamesIsSentOne(canShow: Bool) async throws {
        let fake = try FakeRightyo(Self.namedFixture)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20))
        let capabilities = AmbientOverheardTests.capable + (canShow ? [AmbientOverheard.namesCapability] : [])
        let pair = try await FallbackSocketPair.connect(
            port: env.port, selecting: [RecipientTestRig.target], capabilities: capabilities
        )
        defer { pair.close() }
        let socket = pair.sockets[0]
        try await recipientSocketSend(sessionFrame(payload: .control(.overheardScope(scope: "everyone"))), on: socket)
        try await recipientSocketBarrier(on: socket)
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: socket)
        #expect(try await recipientSocketReceive(on: socket).payload == .control(.ambientOverheard(
            targetID: RecipientTestRig.target, text: "The review is scheduled for Friday.", speaker: "other",
            name: canShow ? "Ben" : nil
        )))
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
    }
}
#endif
