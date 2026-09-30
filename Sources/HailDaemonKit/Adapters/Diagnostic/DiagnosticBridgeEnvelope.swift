public import Foundation
import HailProtocol

public enum DiagnosticBridgeError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidEnvelope, contextRequired, stopped, capacityExceeded, duplicateRequest
}

public enum DiagnosticBridgeFailure: Sendable, Equatable {
    case publisherFailed, cancelled, stopped
}

/// Counts publication callback outcomes, never proof of physical hearing. No input, UUID or raw error fields.
public struct DiagnosticBridgeDiagnostics: Sendable, Equatable {
    public var queued = 0
    public var active = 0
    public var completed = 0
    public var failed = 0
    public var cancelled = 0
    public var lastFailure: DiagnosticBridgeFailure?
}

/// Only retained routing metadata and a fixed diagnostic phrase reach the injected publisher.
public struct DiagnosticBridgeReply: Sendable, Equatable {
    public let requestID: UUID
    public let hostID: String
    public let targetID: String
    public let sequence: Int
    public var text: String { "Hailing Station diagnostic reply \(sequence). Over to you." }
}

/// A bounded, exactly one-line envelope. Unknown/duplicate fields, nonliteral version 1 and wrong
/// types fail closed. The small scanner delegates JSON string escape/Unicode validation to JSONDecoder.
struct DiagnosticBridgeEnvelope {
    let requestID: UUID
    let text: String

    static func encode(requestID: UUID, text: String) throws -> Data {
        let value: [String: JSONValue] = ["version": .integer(1), "request": .string(requestID.uuidString),
                                          "text": .string(text)]
        var data = try JSONEncoder().encode(value)
        data.append(10)
        _ = try decode(data)
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= PayloadLimits.defaultMaxFrameBytes + 1, data.last == 10,
              !data.dropLast().contains(10), !data.dropLast().contains(13) else {
            throw DiagnosticBridgeError.invalidEnvelope
        }
        var scanner = EnvelopeScanner(bytes: Array(data.dropLast()))
        let values = try scanner.object()
        guard let raw = values["request"], raw.utf8.count == 36, let requestID = UUID(uuidString: raw),
              let text = values["text"], !text.isEmpty, text.contains(where: { !$0.isWhitespace }),
              !text.contains(where: \.isNewline), text.utf8.count <= PayloadLimits.maxTextBytes else {
            throw DiagnosticBridgeError.invalidEnvelope
        }
        return Self(requestID: requestID, text: text)
    }
}

private struct EnvelopeScanner {
    let bytes: [UInt8]
    var offset = 0

    mutating func object() throws -> [String: String] {
        try consume(123)
        var seen = Set<String>()
        var strings: [String: String] = [:]
        for index in 0..<3 {
            if index > 0 { try consume(44) }
            let key = try string()
            guard ["version", "request", "text"].contains(key), seen.insert(key).inserted else { throw invalid() }
            try consume(58)
            if key == "version" { try consume(49) } else { strings[key] = try string() }
        }
        try consume(125)
        whitespace()
        guard offset == bytes.count, seen.count == 3 else { throw invalid() }
        return strings
    }

    mutating func consume(_ expected: UInt8) throws {
        whitespace()
        guard offset < bytes.count, bytes[offset] == expected else { throw invalid() }
        offset += 1
    }

    mutating func string() throws -> String {
        whitespace()
        let start = offset
        try consume(34)
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if escaped { escaped = false; continue }
            if byte == 92 { escaped = true; continue }
            if byte == 34 {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else {
                    throw invalid()
                }
                return value
            }
        }
        throw invalid()
    }

    mutating func whitespace() {
        while offset < bytes.count, bytes[offset] == 32 || bytes[offset] == 9 { offset += 1 }
    }

    func invalid() -> DiagnosticBridgeError { .invalidEnvelope }
}
