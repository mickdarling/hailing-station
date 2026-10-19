import Foundation
import Testing
@testable import HailCore

func coachingWireFixture() throws -> [Data] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("fixtures/coaching-wire-v1.jsonl"), encoding: .utf8)
    return source.split(separator: "\n").map { Data($0.utf8) }
}

func coachingWireObject() throws -> [String: Any] {
    let fixture = try coachingWireFixture()
    return try #require(JSONSerialization.jsonObject(with: fixture[2]) as? [String: Any])
}

func coachingWireData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// The authored fixture's synthetic text/schema is preserved; actual host-issued runtime IDs replace example IDs.
func coachingWireData(_ lease: CoachingQualification, requestID: UUID = UUID(), ttl: Int = 1_000) throws -> Data {
    var object = try coachingWireObject()
    object["session_id"] = lease.sessionID.uuidString.lowercased()
    object["generation_id"] = lease.generation.uuidString.lowercased()
    object["destination_id"] = lease.destinationID.uuidString.lowercased()
    object["qualification_id"] = lease.qualificationID.uuidString.lowercased()
    object["request_id"] = requestID.uuidString.lowercased()
    object["valid_for_ms"] = ttl
    return try coachingWireData(object)
}

@MainActor
func coachingConsumer(_ rig: CoachingTestHarness) throws -> CoachingAdviceConsumer {
    try CoachingAdviceConsumer(session: rig.session, listenerID: "private-coach")
}
