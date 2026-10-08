import Foundation
import Testing
@testable import HailDaemonKit

/// Conversation mode (rightyo#82) against the producer's real streams: `conversation` events and follow-up requests
/// whose recipient is `unknown` are admitted only on a session that advertised `conversation` at `started`.
extension RightyoInputConsumerTests {
    /// Streams RightyO cbbcb1b emits from its own `tests/test_conversation.py` helpers, captured verbatim: a request,
    /// a follow-up with recipient `unknown`, then "Thanks, that's all."; and a request, a turn to another person,
    /// a second request, then a lapse to ambient on timeout.
    @Test(arguments: [("conversation-producer-follow-up", 2, 2), ("conversation-producer-timeout", 2, 4)])
    func producerConversationStreamsValidateDryToTheEnd(name: String, requests expected: Int, changes: Int)
        async throws {
        let dry = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run",
                                           session: "conversation-test")
        var requests = 0
        for line in try Self.conversationLines(name) {
            requests += try await dry.consume(RightyoInputEvent.decode(line)) ? 1 : 0
        }
        try await dry.finish()
        #expect(requests == expected)
        #expect(await dry.conversationStatus.changes == changes)
        #expect(await dry.conversationStatus.state == "ambient")
    }

    @Test func conversationEventsAreRefusedWithoutTheAdvertisement() async throws {
        let dry = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run",
                                           session: "conversation-test")
        let lines = try Self.conversationLines("conversation-producer-timeout").map(Self.withoutAdvertisement)
        var refused = false
        for line in lines {
            do { _ = try await dry.consume(RightyoInputEvent.decode(line)) } catch {
                #expect(error as? RightyoInputError == .invalidEvent)
                #expect(try Self.type(of: line) == "conversation")
                refused = true
                break
            }
        }
        #expect(refused)
    }

    /// A follow-up's `unknown` recipient is a request only under conversation mode; without the advertisement its
    /// attention is refused before any request could cite it.
    @Test func aFollowUpIsRefusedWithoutTheAdvertisement() async throws {
        let dry = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run",
                                           session: "conversation-test")
        let lines = try Self.conversationLines("conversation-producer-follow-up").map(Self.withoutAdvertisement)
            .filter { try Self.type(of: $0) != "conversation" }
        var refusedAt: String?
        for line in lines {
            do { _ = try await dry.consume(RightyoInputEvent.decode(line)) } catch {
                refusedAt = try Self.type(of: line)
                break
            }
        }
        #expect(refusedAt == "attention")
    }

    @Test(arguments: [
        // Engagement must name its request, and a later window end.
        ["state": "engaged", "reason": "request", "speaker_id": "Speaker A", "at_ms": 900, "until_ms": 900,
         "utterance_id": "t1", "request_id": "conversation-test:t1"],
        ["state": "engaged", "reason": "timeout", "speaker_id": "Speaker A", "at_ms": 900, "until_ms": 9000,
         "utterance_id": "t1", "request_id": "conversation-test:t1"],
        ["state": "engaged", "reason": "request", "speaker_id": "Speaker A", "at_ms": 900, "until_ms": 9000,
         "utterance_id": "t1", "request_id": "other-session:t1"],
        // A timeout names no turn; other returns to ambient name one; no window end on ambient.
        ["state": "ambient", "reason": "timeout", "speaker_id": "Speaker A", "at_ms": 900, "utterance_id": "t1"],
        ["state": "ambient", "reason": "closed", "speaker_id": "Speaker A", "at_ms": 900],
        ["state": "ambient", "reason": "closed", "speaker_id": "Speaker A", "at_ms": 900, "utterance_id": "t1",
         "until_ms": 9000],
        ["state": "paused", "reason": "closed", "speaker_id": "Speaker A", "at_ms": 900, "utterance_id": "t1"],
        ["state": "ambient", "reason": "bored", "speaker_id": "Speaker A", "at_ms": 900, "utterance_id": "t1"],
        ["state": "ambient", "reason": "closed", "at_ms": 900, "utterance_id": "t1"],
        ["state": "ambient", "reason": "closed", "speaker_id": "Speaker A", "at_ms": 99_999, "utterance_id": "t1"],
        ["state": "ambient", "reason": "closed", "speaker_id": "Speaker A", "at_ms": 900, "utterance_id": "t1",
         "scope": ["playback"]]
    ] as [[String: any Sendable]])
    func malformedConversationEventsAreRefused(fields: [String: any Sendable]) throws {
        var payload: [String: Any] = ["schema_version": 1, "type": "conversation", "session_id": "conversation-test",
                                      "sequence": 5, "emitted_at_ms": 10000]
        for (key, value) in fields { payload[key] = value }
        let parsed = try RightyoInputEvent.decode(JSONSerialization.data(withJSONObject: payload))
        #expect(throws: RightyoInputError.invalidEvent) {
            try parsed.validate(session: "conversation-test", enrolled: false)
        }
    }

    @Test func conversationFieldsRideOnlyOnTheirEvents() throws {
        let payload: [String: Any] = ["schema_version": 1, "type": "session", "session_id": "conversation-test",
                                      "sequence": 9, "emitted_at_ms": 10000, "phase": "stopped",
                                      "state": "engaged"]
        let parsed = try RightyoInputEvent.decode(JSONSerialization.data(withJSONObject: payload))
        #expect(throws: RightyoInputError.invalidEvent) {
            try parsed.validate(session: "conversation-test", enrolled: false)
        }
    }

    private static func conversationLines(_ name: String) throws -> [Data] {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/rightyo/\(name).jsonl")
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
    }

    private static func withoutAdvertisement(_ line: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return line }
        object.removeValue(forKey: "conversation")
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func type(of line: Data) throws -> String? {
        (try JSONSerialization.jsonObject(with: line) as? [String: Any])?["type"] as? String
    }
}
