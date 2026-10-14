import Foundation

/// Small lexical pass after Foundation's syntax validation. Preserves duplicate keys and integer spelling,
/// which a decoded dictionary alone loses. The v1 schema intentionally has no repeated key names at any depth.
enum CoachingWireShape {
    static let fields: Set<String> = [
        "schema_version", "type", "session_id", "generation_id", "destination_id", "qualification_id",
        "request_id", "listener_id", "delivery", "valid_for_ms", "text", "decision",
        "label", "confidence", "provider", "model"
    ]

    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 8_192, data.allSatisfy({ $0 < 128 }),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decision = object["decision"] as? [String: Any],
              Set(object.keys) == fields.subtracting(["label", "confidence", "provider", "model"]),
              Set(decision.keys) == ["label", "confidence", "provider", "model"] else {
            throw CoachingWireError.invalidMessage
        }
        let tokens = try keysAndValues(Array(data))
        guard Set(tokens.keys) == fields else { throw CoachingWireError.invalidMessage }
        for key in ["schema_version", "valid_for_ms"] {
            guard let raw = tokens[key], !raw.isEmpty, raw.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                throw CoachingWireError.invalidMessage
            }
        }
    }

    private static func keysAndValues(_ bytes: [UInt8]) throws -> [String: [UInt8]] {
        var result: [String: [UInt8]] = [:]
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 34 else { index += 1; continue }
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != 34 {
                index += bytes[index] == 92 ? 2 : 1
            }
            guard index < bytes.count else { throw CoachingWireError.invalidMessage }
            let end = index
            index += 1
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == 58 else { continue }
            let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...end]))
            guard result[key] == nil else { throw CoachingWireError.invalidMessage }
            index += 1
            skipWhitespace(bytes, &index)
            let valueStart = index
            while index < bytes.count, ![44, 125, 93, 32, 9, 10, 13].contains(bytes[index]) { index += 1 }
            result[key] = Array(bytes[valueStart..<index])
            // Revisit the value: strings and nested keys must still be lexed, not skipped as raw tokens.
            index = valueStart
        }
        return result
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, [32, 9, 10, 13].contains(bytes[index]) { index += 1 }
    }
}
