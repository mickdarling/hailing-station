import Foundation
import HailDaemonKit

/// One-shot local controls; the daemon owns deadlines. This command never polls a clock or renews a request.
func progress(_ arguments: ArraySlice<String>) async throws {
    let (request, socket) = try ProgressOptions.parse(arguments)
    var line = try JSONEncoder().encode(request)
    line.append(UInt8(ascii: "\n"))
    let response = try await ReplyClient.transact(line, socketURL: socket)
    guard let report = response.progress else { fail("task progress unavailable; inspect haild daemon capabilities") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let output = String(data: try encoder.encode(report), encoding: .utf8) else {
        fail("invalid progress report")
    }
    print(output)
    if report.outcome == "refused" || report.outcome == "not_enabled" { exit(1) }
}

enum ProgressOptions {
    static let usage = """
           haild progress start <target-id> [--task <UUID>] [--every <15..3600 seconds>] [--socket <path>]
           haild progress status [--socket <path>]
           haild progress interval <task-UUID> --every <seconds> [--socket <path>]
           haild progress owner <task-UUID> --command <exact-owner-control> [--socket <path>]
           haild progress report <task-UUID> --token <wake-UUID> [--say <update>] [--card <details>]
           haild progress finish <task-UUID> [--say <completion>] [--card <details>]
           haild progress cancel <task-UUID>
      (off unless daemon runs --personal-terminal --session-updates --task-progress; no request renewal)
    """

    static func parse(_ arguments: ArraySlice<String>) throws -> (LocalTaskProgressRequest, URL) {
        var rest = arguments
        guard let raw = rest.popFirst(), let action = LocalTaskProgressRequest.Action(rawValue: raw) else {
            throw ReplyCommandError.usage
        }
        var request = LocalTaskProgressRequest(action: action)
        if action == .start {
            guard let target = rest.popFirst(), !target.hasPrefix("-") else { throw ReplyCommandError.usage }
            request.target = target
        } else if action != .status {
            guard let raw = rest.popFirst(), let task = UUID(uuidString: raw) else { throw ReplyCommandError.usage }
            request.task = task
        }
        var socket = LocalReplyEndpoint.standardSocket(), seen: Set<String> = []
        while let flag = rest.popFirst() {
            guard seen.insert(flag).inserted, let value = rest.popFirst(), !value.isEmpty else {
                throw ReplyCommandError.usage
            }
            if flag == "--socket" { socket = URL(fileURLWithPath: value) } else {
                try apply(flag, value: value, request: &request)
            }
        }
        if action == .start && request.task == nil { request.task = UUID() }
        guard action != .interval || request.seconds != nil, action != .owner || request.command != nil,
              action != .report || request.token != nil,
              request.seconds.map({ (15...3_600).contains($0) }) ?? true else { throw ReplyCommandError.usage }
        return (request, socket)
    }

    private static func apply(_ flag: String, value: String, request: inout LocalTaskProgressRequest) throws {
        let action = request.action
        switch flag {
        case "--task" where action == .start: request.task = try uuid(value)
        case "--every" where action == .start || action == .interval:
            guard let seconds = Int(value) else { throw ReplyCommandError.usage }
            request.seconds = seconds
        case "--command" where action == .owner: request.command = value
        case "--token" where action == .report: request.token = try uuid(value)
        case "--say" where action == .report || action == .finish: request.text = value
        case "--card" where action == .report || action == .finish: request.card = value
        default: throw ReplyCommandError.usage
        }
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let result = UUID(uuidString: value) else { throw ReplyCommandError.usage }
        return result
    }
}
