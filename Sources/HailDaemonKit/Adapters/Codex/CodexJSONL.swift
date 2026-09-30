import Foundation
import HailProtocol

enum CodexStdioError: Error, Sendable, Equatable {
    case invalidConfiguration, stopped, transportLost, malformedFrame, oversizedFrame, truncatedFrame
    case capacityExceeded, timedOut, unknownResponse, serverRequest, providerRefused
}
enum CodexStdioMethod: String, Sendable { case initialize, threadStart = "thread/start", turnStart = "turn/start" }
enum CodexStdioNotice: String, Sendable { case initialized }
struct CodexStdioLimits: Sendable {
    var requestTimeout: Duration = .seconds(2)
    var maxRequests = 4
    var maxNotifications = 32
    var maxNotificationBytes = 65_536
    var maxFrameBytes = 65_536
    var terminationGrace: TimeInterval = 0.1
}
struct CodexStdioNotification: Sendable, Equatable {
    let method: String
    let params: JSONValue
}

/// Validates byte/depth/key bounds before JSONDecoder can allocate a recursive value or collapse duplicate keys.
private struct BoundedJSONSyntax {
    let bytes: [UInt8]
    var index = 0
    var tokens = 0

    mutating func validate() throws {
        try value(depth: 0); whitespace()
        guard index == bytes.count else { throw CodexStdioError.malformedFrame }
    }
    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    private mutating func take(_ byte: UInt8) throws {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { throw CodexStdioError.malformedFrame }
        index += 1
    }
    private mutating func value(depth: Int) throws {
        tokens += 1; whitespace()
        guard depth <= 16, tokens <= 2_048, index < bytes.count else { throw CodexStdioError.malformedFrame }
        switch bytes[index] {
        case 123:
            guard depth < 16 else { throw CodexStdioError.malformedFrame }
            try object(depth: depth + 1)
        case 91:
            guard depth < 16 else { throw CodexStdioError.malformedFrame }
            try array(depth: depth + 1)
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw CodexStdioError.malformedFrame }
        }
    }
    private mutating func object(depth: Int) throws {
        try take(123); whitespace()
        if index < bytes.count, bytes[index] == 125 { index += 1; return }
        var keys = Set<String>()
        while true {
            let key = try string()
            guard keys.insert(key).inserted else { throw CodexStdioError.malformedFrame }
            try take(58); try value(depth: depth); whitespace()
            guard index < bytes.count else { throw CodexStdioError.malformedFrame }
            if bytes[index] == 125 { index += 1; return }
            try take(44)
        }
    }
    private mutating func array(depth: Int) throws {
        try take(91); whitespace()
        if index < bytes.count, bytes[index] == 93 { index += 1; return }
        while true {
            try value(depth: depth); whitespace()
            guard index < bytes.count else { throw CodexStdioError.malformedFrame }
            if bytes[index] == 93 { index += 1; return }
            try take(44)
        }
    }
    private mutating func string() throws -> String {
        whitespace(); let start = index; try take(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) } catch {
                    throw CodexStdioError.malformedFrame
                }
            }
            if byte == 92 { index += 1 }
        }
        throw CodexStdioError.malformedFrame
    }
}

struct CodexJSONL {
    let maxFrameBytes: Int
    private var pending = Data()
    init(maxFrameBytes: Int = 65_536) throws {
        guard (1...65_536).contains(maxFrameBytes) else { throw CodexStdioError.invalidConfiguration }
        self.maxFrameBytes = maxFrameBytes
    }
    mutating func append(_ chunk: Data, receive: (JSONValue, Int) throws -> Void) throws {
        for byte in chunk {
            if byte == 10 {
                let count = pending.count
                let value = try Self.decode(pending); pending.removeAll(keepingCapacity: true)
                try receive(value, count)
            } else {
                guard pending.count < maxFrameBytes else { throw CodexStdioError.oversizedFrame }
                pending.append(byte)
            }
        }
    }
    func finish() throws {
        guard pending.isEmpty else { throw CodexStdioError.truncatedFrame }
    }
    static func decode(_ data: Data) throws -> JSONValue {
        guard String(data: data, encoding: .utf8) != nil else { throw CodexStdioError.malformedFrame }
        var syntax = BoundedJSONSyntax(bytes: Array(data)); try syntax.validate()
        do { return try JSONDecoder().decode(JSONValue.self, from: data) } catch {
            throw CodexStdioError.malformedFrame
        }
    }
    static func encode(_ value: JSONValue) throws -> Data {
        var tokens = 0, bytes = 65_536
        try bound(value, depth: 0, tokens: &tokens, bytes: &bytes)
        do { return try JSONEncoder().encode(value) } catch { throw CodexStdioError.malformedFrame }
    }
    private static func bound(_ value: JSONValue, depth: Int, tokens: inout Int, bytes: inout Int) throws {
        tokens += 1; bytes -= 1
        guard depth <= 16, tokens <= 2_048, bytes >= 0 else { throw CodexStdioError.malformedFrame }
        switch value {
        case .string(let text): bytes -= text.utf8.count
        case .array(let values):
            for value in values { try bound(value, depth: depth + 1, tokens: &tokens, bytes: &bytes) }
        case .object(let values):
            for (key, value) in values {
                bytes -= key.utf8.count
                try bound(value, depth: depth + 1, tokens: &tokens, bytes: &bytes)
            }
        default: break
        }
        guard bytes >= 0 else { throw CodexStdioError.oversizedFrame }
    }
}

enum CodexRPCEnvelope: Sendable {
    case response(Int64, JSONValue), refusal(Int64), notification(String, JSONValue)

    init(_ value: JSONValue) throws {
        guard case .object(let object) = value else { throw CodexStdioError.malformedFrame }
        if case .string(let method) = object["method"] {
            guard object["id"] == nil else { throw CodexStdioError.serverRequest }
            guard object["result"] == nil, object["error"] == nil,
                  Set(object.keys).isSubset(of: ["method", "params"]), method.utf8.count <= 256 else {
                throw CodexStdioError.malformedFrame
            }
            self = .notification(method, object["params"] ?? .null)
        } else {
            guard case .integer(let id) = object["id"], id > 0, object["method"] == nil,
                  Set(object.keys).isSubset(of: ["id", "result", "error"]),
                  (object["result"] == nil) != (object["error"] == nil) else {
                throw CodexStdioError.malformedFrame
            }
            self = object["error"] == nil ? .response(id, object["result"] ?? .null) : .refusal(id)
        }
    }
}
