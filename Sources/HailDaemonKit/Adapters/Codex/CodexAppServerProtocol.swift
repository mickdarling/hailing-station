#if os(macOS)
import Foundation
import CryptoKit
import HailProtocol

enum CodexAppServerError: Error, Sendable, Equatable {
    case incompatibleVersion, unavailable, invalidProtocol, turnInProgress, capacityExceeded
}
enum CodexAppServerProtocol {
    /// Exact CLI versions whose stable schema covers every shape used here (#153, #399).
    static let supportedVersions: Set<String> = ["0.159.0", "0.162.0-alpha.17.2"]
    static func start(_ transport: CodexStdioTransport, workspace: String) async throws -> String {
        let hello = try await transport.request(.initialize, params: .object([
            "clientInfo": .object(["name": .string("hailing_station"), "version": .string("0.1.25")]),
            "capabilities": .object(["experimentalApi": .bool(false)])
        ]))
        let object = try fields(hello)
        guard case .string = object["userAgent"], case .string = object["codexHome"],
              object["platformFamily"] == .string("unix"), object["platformOs"] == .string("macos") else {
            throw CodexAppServerError.invalidProtocol
        }
        try await transport.notify(.initialized)
        let response = try fields(try await transport.request(.threadStart, params: .object([
            "ephemeral": .bool(true), "approvalPolicy": .string("never"),
            "approvalsReviewer": .string("user"), "sandbox": .string("read-only"), "cwd": .string(workspace)
        ])))
        // The owner's own instruction files may load (#153 revision); the cwd must be the owned workspace.
        guard response["cwd"] == .string(workspace) else { throw CodexAppServerError.invalidProtocol }
        let sandbox = try fields(response["sandbox"] ?? .null)
        let thread = try fields(response["thread"] ?? .null)
        guard response["approvalPolicy"] == .string("never"), response["approvalsReviewer"] == .string("user"),
              sandbox["type"] == .string("readOnly"),
              Set(sandbox.keys).isSubset(of: ["type", "networkAccess"]),
              sandbox["networkAccess"] == nil || sandbox["networkAccess"] == .bool(false),
              thread["ephemeral"] == .bool(true) else { throw CodexAppServerError.invalidProtocol }
        return try identifier(thread["id"])
    }
    static func turnInput(_ text: String, threadID: String) throws -> JSONValue {
        guard !text.isEmpty, text.utf8.count <= ProviderEventLimits.maxTextBytes,
              !text.contains("\n"), !text.contains("\r") else { throw CodexAppServerError.invalidProtocol }
        return .object([
            "threadId": .string(threadID), "input": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "approvalPolicy": .string("never"),
            "sandboxPolicy": .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
        ])
    }
    static func turnID(_ response: JSONValue) throws -> String {
        let object = try fields(response), turn = try fields(object["turn"] ?? .null)
        guard turn["status"] == .string("inProgress"), turn["error"] == nil || turn["error"] == .null,
              case .array = turn["items"] else { throw CodexAppServerError.invalidProtocol }
        return try identifier(turn["id"])
    }
    static func fields(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let fields) = value else { throw CodexAppServerError.invalidProtocol }
        return fields
    }
    static func identifier(_ value: JSONValue?) throws -> String {
        guard case .string(let text) = value, !text.isEmpty,
              text.utf8.count <= ProviderEventLimits.maxIdentifiers else {
            throw CodexAppServerError.invalidProtocol
        }
        return text
    }
}
struct CodexAppServerRecord: Sendable {
    enum Kind: Sendable { case accepted, item(String, String?, Data), terminal(ProviderEventKind) }
    let threadID: String
    let turnID: String
    let kind: Kind
    var bytes: Int {
        var size = threadID.utf8.count + turnID.utf8.count
        if case .item(let id, let text, _) = kind { size += id.utf8.count + (text?.utf8.count ?? 0) + 32 }
        return size
    }
    init?(_ notification: CodexStdioNotification) throws {
        guard ["turn/started", "turn/completed", "item/completed"].contains(notification.method) else { return nil }
        let object = try CodexAppServerProtocol.fields(notification.params)
        threadID = try CodexAppServerProtocol.identifier(object["threadId"])
        if notification.method == "item/completed" {
            turnID = try CodexAppServerProtocol.identifier(object["turnId"])
            let item = try CodexAppServerProtocol.fields(object["item"] ?? .null)
            let id = try CodexAppServerProtocol.identifier(item["id"])
            kind = .item(id, try Self.visibleText(item), try Self.fingerprint(item))
        } else {
            let turn = try CodexAppServerProtocol.fields(object["turn"] ?? .null)
            guard case .array = turn["items"] else { throw CodexAppServerError.invalidProtocol }
            turnID = try CodexAppServerProtocol.identifier(turn["id"])
            if notification.method == "turn/started" {
                guard turn["status"] == .string("inProgress"), turn["error"] == nil || turn["error"] == .null else {
                    throw CodexAppServerError.invalidProtocol
                }
                kind = .accepted
            } else { kind = .terminal(try Self.terminal(turn)) }
        }
    }
    private static func visibleText(_ item: [String: JSONValue]) throws -> String? {
        guard item["type"] == .string("agentMessage") else { return nil }
        guard item["delivery"] == nil || item["delivery"] == .null || item["delivery"] == .string("async") else {
            throw CodexAppServerError.invalidProtocol
        }
        guard item["phase"] == .string("final_answer"), item["delivery"] != .string("async"),
              try noQuestions(item["questions"]) else { return nil }
        guard case .string(let text) = item["text"], text.utf8.count <= ProviderEventLimits.maxTextBytes else {
            throw CodexAppServerError.invalidProtocol
        }
        return text
    }
    private static func noQuestions(_ value: JSONValue?) throws -> Bool {
        if value == nil || value == .null { return true }
        guard case .array(let questions) = value else { throw CodexAppServerError.invalidProtocol }
        return questions.isEmpty // The pinned schema permits an empty array: it contains no questions.
    }
    private static func fingerprint(_ item: [String: JSONValue]) throws -> Data {
        _ = try CodexJSONL.encode(.object(item)) // Bounds precede canonicalization allocation.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        do { return Data(SHA256.hash(data: try encoder.encode(JSONValue.object(item)))) } catch {
            throw CodexAppServerError.invalidProtocol
        }
    }
    private static func terminal(_ turn: [String: JSONValue]) throws -> ProviderEventKind {
        switch turn["status"] {
        case .string("completed"):
            guard turn["error"] == nil || turn["error"] == .null else { throw CodexAppServerError.invalidProtocol }
            return .finished
        case .string("interrupted"): return .interrupted
        case .string("failed"): return .failed(.providerFailed)
        default: throw CodexAppServerError.invalidProtocol
        }
    }
}
#endif
