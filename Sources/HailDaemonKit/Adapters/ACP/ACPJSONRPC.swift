import Foundation
import HailProtocol

enum ACPJSONRPCError: Error, Sendable, Equatable {
    case malformedFrame, oversizedFrame, exhaustedIDs
}

struct ACPAgentRequest: Sendable, Equatable {
    let id: Int64
    let method: String
    let params: JSONValue
}

enum ACPJSONRPCMessage: Sendable, Equatable {
    case result(id: Int64, value: JSONValue)
    // Agent error text/data is discarded at the boundary, never carried into an Error or diagnostic.
    case error(id: Int64, code: Int64, messageBytes: Int)
    case agentRequest(ACPAgentRequest)
    case notification(method: String, params: JSONValue)
}

/// One JSON-RPC 2.0 object per line. No dispatch, logging, or agent-request execution in this layer.
struct ACPJSONRPC {
    private var nextID: Int64 = 1

    mutating func request(method: String, params: JSONValue = .object([:])) throws -> Data {
        guard nextID < Int64.max else { throw ACPJSONRPCError.exhaustedIDs }
        let line = try Self.encode(["id": .integer(nextID), "method": .string(method), "params": params])
        nextID += 1 // Failed encoding does not spend an identity.
        return line
    }

    static func notification(method: String, params: JSONValue = .object([:])) throws -> Data {
        try encode(["method": .string(method), "params": params])
    }

    static func result(id: Int64, value: JSONValue) throws -> Data {
        try encode(["id": .integer(id), "result": value])
    }

    /// Only client-owned fixed error text is emitted. Never reflect a method, params, or agent error message.
    static func error(id: Int64, code: Int64) throws -> Data {
        try encode(["id": .integer(id), "error": .object([
            "code": .integer(code), "message": .string(code == -32601 ? "Method not found" : "Request failed")
        ])])
    }

    /// Every agent request is unsupported in slice 1, including all fs/* and terminal/* methods.
    static func refusal(for request: ACPAgentRequest) throws -> Data {
        try error(id: request.id, code: -32601)
    }

    /// Accept a line with or without its final LF. Embedded LF/multiple frames are always refused.
    static func decode(_ line: Data) throws -> ACPJSONRPCMessage {
        guard line.count <= 65_536 + (line.last == 10 ? 1 : 0) else { throw ACPJSONRPCError.oversizedFrame }
        var data = line
        if data.last == 10 { data.removeLast() }
        guard data.count <= 65_536 else { throw ACPJSONRPCError.oversizedFrame }
        guard !data.contains(10) else { throw ACPJSONRPCError.malformedFrame }
        let value: JSONValue
        do {
            // Reuse CodexJSONL's UTF-8, depth (16), token (2,048), and decoded duplicate-key validator.
            value = try CodexJSONL.decode(data)
        } catch { throw ACPJSONRPCError.malformedFrame }
        return try message(value)
    }

    private static func message(_ value: JSONValue) throws -> ACPJSONRPCMessage {
        guard case .object(let object) = value, object["jsonrpc"] == .string("2.0") else {
            throw ACPJSONRPCError.malformedFrame
        }
        if case .string(let method) = object["method"] {
            guard Set(object.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
                  validParams(object["params"]) else { throw ACPJSONRPCError.malformedFrame }
            let params = object["params"] ?? .object([:])
            if let id = object["id"] {
                guard case .integer(let id) = id else { throw ACPJSONRPCError.malformedFrame }
                return .agentRequest(ACPAgentRequest(id: id, method: method, params: params))
            }
            return .notification(method: method, params: params)
        }
        return try response(object)
    }

    private static func response(_ object: [String: JSONValue]) throws -> ACPJSONRPCMessage {
        guard Set(object.keys).isSubset(of: ["jsonrpc", "id", "result", "error"]),
              case .integer(let id) = object["id"],
              (object["result"] == nil) != (object["error"] == nil) else {
            throw ACPJSONRPCError.malformedFrame
        }
        if let result = object["result"] { return .result(id: id, value: result) }
        guard case .object(let error) = object["error"],
              Set(error.keys).isSubset(of: ["code", "message", "data"]),
              case .integer(let code) = error["code"], case .string(let message) = error["message"] else {
            throw ACPJSONRPCError.malformedFrame
        }
        return .error(id: id, code: code, messageBytes: message.utf8.count)
    }

    private static func validParams(_ params: JSONValue?) -> Bool {
        switch params {
        case nil, .object, .array: true
        default: false
        }
    }

    private static func encode(_ fields: [String: JSONValue]) throws -> Data {
        var object = fields
        object["jsonrpc"] = .string("2.0")
        let data: Data
        do { data = try CodexJSONL.encode(.object(object)) } catch CodexStdioError.oversizedFrame {
            throw ACPJSONRPCError.oversizedFrame
        } catch { throw ACPJSONRPCError.malformedFrame }
        // Check the actual encoded byte count and precisely the same syntax bounds on both directions.
        _ = try decode(data)
        return data + Data([10])
    }
}
