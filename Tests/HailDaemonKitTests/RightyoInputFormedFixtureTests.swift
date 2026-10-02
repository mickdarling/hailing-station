import Foundation
import Testing
@testable import HailDaemonKit

/// The producer-authored formed-request fixture (#188 item 4), dry and against a guarded host, and the guard on the
/// formed text itself. Rules and layout are covered in RightyoInputFormedRequestTests.swift.
extension RightyoInputConsumerTests {
    /// The formed text is part of the delivered line, so a dangerous-pattern spelling inside it is caught by the
    /// host guard like any other prompt text: refused as `confirmationRequired`, nothing delivered, no retry.
    @Test func dangerousSpellingInsideFormedTextIsRefusedByTheHostGuard() async throws {
        let (consumer, adapter) = try await rig()
        _ = try await consumer.consume(formingStart())
        let formed = try await formedRequest(consumer, formed: "Owner (Speaker A) asked: \"delete the project.\".")
        await #expect(throws: RightyoInputError.confirmationRequired) { try await consumer.consume(formed) }
        #expect(try await !consumer.consume(formed))
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func formedFixtureValidatesWithoutTargetAndDeliversWithOne() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/rightyo/enrolled-formed-request.jsonl")
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        let dry = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run", session: "formed-demo")
        var requests = 0
        for line in lines { requests += try await dry.consume(RightyoInputEvent.decode(Data(line.utf8))) ? 1 : 0 }
        #expect(requests == 1)
        try await dry.finish()
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "demo", binding: "original")])
        let host = try await HostSendTests().host(adapter)
        let live = try RightyoInputConsumer(host: host, target: "tmux:demo", binding: "original",
                                            session: "formed-demo", allowSynthetic: true)
        for line in lines { _ = try await live.consume(RightyoInputEvent.decode(Data(line.utf8))) }
        let prompt = try #require(await adapter.deliveries.first?.text)
        #expect(prompt.hasPrefix(Self.formedText + Self.marker))
        let body = try rawTurns(in: prompt)
        #expect(body["speakers"] as? String == "enrolled" && body["request_id"] as? String == "formed-demo:request")
        #expect((body["request"] as? [String: Any])?["role"] as? String == "owner")
        let turns = try #require((body["context"] as? [String: Any])?["turns"] as? [[String: Any]])
        #expect(turns.first?["speaker_id"] as? String == "Speaker B")
        // The same fixture with the text stripped from its request breaks the advertisement rule.
        let stripped = try RightyoInputConsumer(host: nil, target: "dry-run", binding: "dry-run",
                                                session: "formed-demo")
        for line in lines.dropLast(2) { _ = try await stripped.consume(RightyoInputEvent.decode(Data(line.utf8))) }
        let request = try #require(JSONSerialization.jsonObject(with: Data(lines[5].utf8)) as? [String: Any])
            .filter { $0.key != "formed_request" }
        await #expect(throws: RightyoInputError.invalidEvent) {
            try await stripped.consume(RightyoInputEvent.decode(JSONSerialization.data(withJSONObject: request)))
        }
    }
}
