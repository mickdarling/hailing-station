public import Foundation

public enum CoachingWireError: Error, Sendable, Equatable {
    case invalidMessage, unknownQualification, wrongScope, replay, ledgerFull, staleAdvice
}

/// Strict v1 suggestion, not a host control, command, authentication credential or action grant.
public struct CoachingWireAdvice: Decodable, Sendable {
    public let sessionID: String
    public let generationID: String
    public let destinationID: String
    public let qualificationID: String
    public let requestID: String
    public let listenerID: String
    public let validForMs: Int
    public let text: String
    private let schemaVersion: Int
    private let type: String
    private let delivery: String
    private let decision: Decision

    private struct Decision: Decodable, Sendable {
        let label: String
        let confidence: Double
        let provider: String
        let model: String
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", generationID = "generation_id", destinationID = "destination_id"
        case qualificationID = "qualification_id", requestID = "request_id", listenerID = "listener_id"
        case validForMs = "valid_for_ms", schemaVersion = "schema_version"
        case text, type, delivery, decision
    }

    public static func decode(_ data: Data) throws -> Self {
        do {
            try CoachingWireShape.validate(data)
            let advice = try JSONDecoder().decode(Self.self, from: data)
            guard advice.isValid else { throw CoachingWireError.invalidMessage }
            return advice
        } catch { throw CoachingWireError.invalidMessage }
    }

    private var isValid: Bool {
        schemaVersion == 1 && type == "coaching_advice" && delivery == "owner_private"
            && (1...2_000).contains(validForMs)
            && [sessionID, generationID, destinationID, qualificationID, requestID].allSatisfy(Self.canonicalUUID)
            && [listenerID, decision.provider, decision.model].allSatisfy(Self.identifier)
            && decision.label == "speak_now" && decision.confidence.isFinite
            && (0...1).contains(decision.confidence) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.unicodeScalars.count <= 280 && text.split(whereSeparator: { $0.isWhitespace }).count <= 45
            && text.unicodeScalars.allSatisfy(Self.printable)
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return value == uuid.uuidString.lowercased()
    }

    static func identifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty && value.utf8.count <= 96 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || [32, 45, 46, 95].contains($0)
        }
    }

    private static func printable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator, .unassigned: false
        case .spaceSeparator: scalar.value == 32
        default: true
        }
    }
}
