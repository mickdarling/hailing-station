#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Overheard remarks (#398): turns RightyO heard but did not send reach only the device that heard them, only within
/// the scope it asked for, before that stream's later requests, and never as the assistant's own echo.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientOverheardTests {
    static let capable = ["probe", AmbientHeard.capability, AmbientOverheard.capability]
    static let clip = AmbientAckClip(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000, text: "On it.")

    private static func line(_ fields: String, sequence: Int) throws -> RightyoInputEvent {
        let prefix = #"{"schema_version": 1, "session_id": "s", "sequence": \#(sequence), "emitted_at_ms": 0, "#
        return try RightyoInputEvent.decode(Data((prefix + fields + "}").utf8))
    }

    private static func transcript(_ id: String, _ text: String, role: String?) throws -> RightyoInputEvent {
        let role = role.map { #", "role": "\#($0)""# } ?? ""
        return try line(#"""
            "type": "transcript", "turn": {"session_id": "s", "utterance_id": "\#(id)", "revision": 1,
             "start_ms": 0, "end_ms": 500, "text": "\#(text)", "finalized": true, "overlap": false,
             "recognizer_id": "r", "provenance": "live-microphone", "speaker_provenance": "none"\#(role)}
            """#, sequence: 1)
    }

    private static func attention(_ id: String, role: String?, request: Bool = false) throws -> RightyoInputEvent {
        let role = role.map { #", "role": "\#($0)""# } ?? ""
        let label = request ? "attend" : "ignore", recipient = request ? "system" : "other_human"
        let requestID = request ? #", "request_id": "s:\#(id)""# : ""
        return try line(#"""
            "type": "attention", "utterance_id": "\#(id)", "speech_end_ms": 500\#(requestID),
             "decision": {"label": "\#(label)", "recipient_kind": "\#(recipient)", "confidence": 1.0,
              "provider": "mock", "model": "m"\#(role)}
            """#, sequence: 2)
    }

    final class Seen: Sendable {
        let list = Mutex<[String]>([])
        func append(_ item: String) { list.withLock { $0.append(item) } }
        var all: [String] { list.withLock { $0 } }
    }

    private func relay(echo: String? = nil) -> (AmbientOverheardRelay, Seen) {
        let seen = Seen()
        let relay = AmbientOverheardRelay(
            onOverheard: { text, owner in seen.append("\(owner ? "owner" : "other"): \(text)") },
            isEcho: { heard in heard == echo }
        )
        return (relay, seen)
    }

    @Test func aTurnDecidedWithoutARequestIsReportedOnceWithItsOwnerRole() async throws {
        let (relay, seen) = relay()
        await relay.observe(try Self.transcript("a", "Pass the salt.", role: "owner"))
        await relay.observe(try Self.attention("a", role: "owner"))
        await relay.observe(try Self.attention("a", role: "owner")) // Already taken: never twice.
        await relay.observe(try Self.transcript("b", "Sounds good.", role: nil))
        await relay.observe(try Self.attention("b", role: nil))
        // Owner on only one of the two records is not the owner (the consumer's own rule).
        await relay.observe(try Self.transcript("c", "Maybe later.", role: "owner"))
        await relay.observe(try Self.attention("c", role: "participant"))
        #expect(seen.all == ["owner: Pass the salt.", "other: Sounds good.", "other: Maybe later."])
    }

    @Test func requestsEchoesAndUnheldTurnsAreNeverReported() async throws {
        let (relay, seen) = relay(echo: "The build passed.")
        await relay.observe(try Self.transcript("r", "Haili, what's next?", role: "owner"))
        await relay.observe(try Self.attention("r", role: "owner", request: true))
        await relay.observe(try Self.transcript("e", "The build passed.", role: nil))
        await relay.observe(try Self.attention("e", role: nil))
        await relay.observe(try Self.attention("never-transcribed", role: "owner"))
        #expect(seen.all.isEmpty)
    }

    @Test func heldTurnsAreBounded() async throws {
        let (relay, seen) = relay()
        for index in 0...AmbientOverheardRelay.maxHeld {
            await relay.observe(try Self.transcript("t\(index)", "turn \(index)", role: nil))
        }
        await relay.observe(try Self.attention("t0", role: nil)) // Dropped as the oldest.
        await relay.observe(try Self.attention("t\(AmbientOverheardRelay.maxHeld)", role: nil))
        #expect(seen.all == ["other: turn \(AmbientOverheardRelay.maxHeld)"])
    }

    /// Through the real listener: with `everyone`, the fixture's ignored remark reaches the phone before the later
    /// request's own words; with the default `off`, nothing overheard is sent.
    @Test(arguments: [true, false])
    func thePhoneGetsOverheardTurnsOnlyWithinItsScope(everyone: Bool) async throws {
        let fake = try FakeRightyo(AmbientAcknowledgementTests.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let acknowledged = Mutex(false)
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20),
            acknowledgements: AmbientAckLibrary(clips: ["rightyo": [Self.clip]]),
            onEvent: { event in if event.event == "ambient_acknowledged" { acknowledged.withLock { $0 = true } } }
        )
        let pair = try await FallbackSocketPair.connect(
            port: env.port, selecting: [RecipientTestRig.target], capabilities: Self.capable
        )
        defer { pair.close() }
        let socket = pair.sockets[0]
        if everyone {
            try await recipientSocketSend(sessionFrame(payload: .control(.overheardScope(scope: "everyone"))),
                                          on: socket)
            try await recipientSocketBarrier(on: socket)
        }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: socket)
        #expect(await eventually { acknowledged.withLock { $0 } })
        if everyone {
            #expect(try await recipientSocketReceive(on: socket).payload == .control(.ambientOverheard(
                targetID: RecipientTestRig.target, text: "The review is scheduled for Friday.", speaker: "other"
            )))
        }
        #expect(try await recipientSocketReceive(on: socket).payload == .control(.ambientHeard(
            targetID: RecipientTestRig.target, text: "Rightyo, check our discussion."
        )))
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
    }

    /// The send itself: only the named connection, only while it selects the target, only a capable device, only within
    /// its scope, and only text the command can carry.
    @Test(arguments: [
        "sent", "owner_scope_other", "owner_scope_owner", "off", "incapable", "other_target", "oversized"
    ])
    func theOverheardFrameIsGuarded(_ expected: String) async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: false)
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [RecipientTestRig.target],
            capabilities: expected == "incapable" ? ["probe"] : Self.capable
        )
        defer { pair.close() }
        let connection = try #require(await listener.overheardTestConnectionID())
        let scope = expected.hasPrefix("owner_scope") ? "owner" : expected == "off" ? "off" : "everyone"
        await listener.overheardTestSetScope(scope)
        var (target, text, owner) = (RecipientTestRig.target, "Pass the salt.", expected == "owner_scope_owner")
        if expected == "other_target" { target = "tmux:elsewhere" }
        if expected == "oversized" { text = String(repeating: "a", count: PayloadLimits.maxTextBytes + 1) }
        let sent = await listener.showAmbientOverheard(
            connection: connection, target: target, text: text, owner: owner
        )
        #expect(sent == ["sent", "owner_scope_owner"].contains(expected))
        if sent {
            let frame = try await recipientSocketReceive(on: pair.sockets[0])
            #expect(frame.payload == .control(.ambientOverheard(
                targetID: target, text: text, speaker: owner ? "owner" : "other"
            )))
        } else {
            try await pair.barrier()
        }
        await listener.stop(reason: "synthetic test complete")
    }
}

extension WebSocketListener {
    fileprivate func overheardTestConnectionID() async -> UUID? {
        guard peers.count == 1, let peer = peers.values.first else { return nil }
        return await peer.session.connectionID
    }

    /// The fallback test listener has no ambient gate, so it does not admit `overheard_scope`; set it directly.
    fileprivate func overheardTestSetScope(_ scope: String) async {
        await peers.values.first?.session.overheardTestSet(scope)
    }
}

extension HostSession {
    fileprivate func overheardTestSet(_ scope: String) { overheardScope = scope }
}
#endif
