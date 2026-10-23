#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// The child's privacy-on ack (#735 S-8 HS-A): `privacy` `on` with a non-negative integer `at_ms`, admitted only from
/// a session that advertised `duck` v3. Decoded only: it never sets `lastPrivacy`, so it plays no clip. Synthetic only.
extension AmbientPrivacyEventTests {
    static let envelope = #""schema_version": 1, "session_id": "s1", "emitted_at_ms": 5"#

    /// A `privacy` line at `sequence` with `action` and `extra` fields (`, "at_ms": …`).
    static func privacy(_ action: String, sequence: Int = 2, extra: String = "") throws -> RightyoInputEvent {
        try RightyoInputEvent.decode(Data(
            #"{"type": "privacy", "action": "\#(action)", "sequence": \#(sequence), \#(envelope)\#(extra)}"#.utf8
        ))
    }

    /// A consumer that has admitted a `started` advertising `duck` at `version`, on a host that handles privacy.
    static func consumer(version: Int) async throws -> RightyoInputConsumer {
        let consumer = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run", session: "s1",
                                                duckActive: { true })
        let caps = #""capabilities": {"activation": "finalized-turn", "context": true, "partials": false, "#
            + #""speakers": "enrolled"}"#
        let started = #"{"type": "session", "phase": "started", "sequence": 1, \#(envelope), \#(caps), "#
            + #""duck": {"version": \#(version)}}"#
        _ = try await consumer.consume(RightyoInputEvent.decode(Data(started.utf8)))
        return consumer
    }

    struct Seen: Equatable {
        let privacy: PrivacyCommand?, ack: Int?
        init(_ privacy: PrivacyCommand?, _ ack: Int?) { (self.privacy, self.ack) = (privacy, ack) }
    }

    /// What the latest line left: its privacy command and its ack.
    static func seen(_ consumer: RightyoInputConsumer) async -> Seen {
        await Seen(consumer.lastPrivacy, consumer.lastPrivacyAck)
    }

    /// `at_ms` is on the child's audio clock, so 0 and a value past `emitted_at_ms` are both admitted.
    @Test(arguments: [0, 1234]) func aVersionThreeAckIsAdmittedAndSetsNoPrivacyCommand(_ atMs: Int) async throws {
        let consumer = try await Self.consumer(version: 3)
        #expect(try await !consumer.consume(Self.privacy("on", extra: #", "at_ms": \#(atMs)"#)))
        #expect(await Self.seen(consumer) == Seen(nil, atMs))
        _ = try await consumer.consume(Self.privacy("status", sequence: 3))
        #expect(await Self.seen(consumer) == Seen(.status, nil))
    }

    @Test func anAckFromAVersionTwoSessionEndsTheStream() async throws {
        let consumer = try await Self.consumer(version: 2)
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(Self.privacy("on", extra: #", "at_ms": 10"#))
        }
    }

    /// `on` requires `at_ms`, a non-negative integer; `exit` and `status` refuse it, from v3 as from v2.
    @Test(arguments: [
        ("on", ""), ("on", #", "at_ms": null"#), ("on", #", "at_ms": -1"#), ("on", #", "at_ms": 1.5"#),
        ("on", #", "at_ms": "10""#), ("exit", #", "at_ms": 10"#), ("status", #", "at_ms": 0"#)
    ])
    func aMalformedAckOrAStrayAtMsIsRefused(_ action: String, _ extra: String) async throws {
        #expect(throws: RightyoInputError.invalidEvent) {
            try Self.privacy(action, extra: extra).validate(session: "s1", enrolled: true)
        }
        let consumer = try await Self.consumer(version: 3)
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await consumer.consume(Self.privacy(action, extra: extra))
        }
    }

    /// A v2 session's `exit` and `status` behave as before the ack: each sets its command, and no ack is seen.
    @Test func versionTwoExitAndStatusAreUnchanged() async throws {
        let consumer = try await Self.consumer(version: 2)
        _ = try await consumer.consume(Self.privacy("exit"))
        #expect(await Self.seen(consumer) == Seen(.exit, nil))
        _ = try await consumer.consume(Self.privacy("status", sequence: 3))
        #expect(await Self.seen(consumer) == Seen(.status, nil))
    }

    /// Through the pipeline a v3 ack plays nothing and ends nothing; from v2 it ends the stream.
    @Test func throughThePipelineAnAckReachesNoClip() async throws {
        let ack = #", \"at_ms\": 500"#
        let (seen, delivered) = try await run(Self.events(["on"], version: 3, extra: ack))
        #expect(seen.isEmpty && delivered == 0)
        await #expect(throws: RightyoInputError.self) { _ = try await run(Self.events(["on"], extra: ack)) }
    }
}
#endif
