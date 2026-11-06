import Darwin
import Foundation
import HailDaemonKit

/// `haild notify` (#609): a local session's unsolicited update, through the running daemon's policy. The daemon
/// holds, delivers a connected card, drops under privacy, or refuses it. Speech availability is separate from card
/// delivery and never means the user heard it. Prints fixed tokens and counts, never the
/// update's words. Exit 0 for held and status; 75 for `rate_limited` (try later); 1 otherwise; 64 usage.
func notify(_ arguments: ArraySlice<String>) async throws {
    let (request, socket) = NotifyOptions.parse(arguments)
    var line = try JSONEncoder().encode(request)
    line.append(UInt8(ascii: "\n"))
    let response: LocalReplyResponse
    do {
        response = try await ReplyClient.transact(line, socketURL: socket)
    } catch ReplyClientError.unanswered(let why) {
        fail("unknown: no answer from the daemon after the update was sent (\(why)); run `haild notify status`")
    }
    guard let report = response.update else {
        guard let error = response.error, response.code != .decodeFailure else {
            fail("refused: \(response.error ?? "no update report") (the daemon may predate `haild notify`;"
                 + " run `haild doctor`)")
        }
        fail("refused: \(error)")
    }
    for output in NotifyText.lines(report) { print(output) }
    exit(NotifyText.exitCode(report))
}

enum NotifyOptions {
    /// `status`, `quiet on`, or `<target-id> --say <text> [--action] [--card <text>]`, each with an optional
    /// `--socket <path>`. Anything else is usage. Quiet goes off only by the user's own control, never from here.
    static func parse(_ arguments: ArraySlice<String>) -> (LocalSessionUpdateRequest, URL) {
        var rest = arguments, socket = LocalReplyEndpoint.standardSocket()
        var request = leading(&rest)
        while let flag = rest.popFirst() {
            if flag == "--socket" {
                socket = URL(fileURLWithPath: value(&rest))
            } else {
                apply(flag, to: &request, from: &rest)
            }
        }
        guard request.target == nil || request.text != nil else { usage() }
        return (request, socket)
    }

    private static func leading(_ rest: inout ArraySlice<String>) -> LocalSessionUpdateRequest {
        guard let first = rest.popFirst(), !first.hasPrefix("-") else { usage() }
        switch (first, first == "quiet" ? rest.popFirst() : nil) {
        case ("status", _): return .init(action: .status)
        case ("quiet", "on"): return .init(action: .quietOn)
        case ("quiet", _): usage()
        default: return .init(action: .submit, target: first)
        }
    }

    /// An update's own flags, each at most once.
    private static func apply(
        _ flag: String, to request: inout LocalSessionUpdateRequest, from rest: inout ArraySlice<String>
    ) {
        let update = request.target != nil
        switch flag {
        case "--say" where update && request.text == nil: request.text = value(&rest)
        case "--card" where update && request.card == nil: request.card = value(&rest)
        case "--action" where update && request.priority == nil: request.priority = .action
        default: usage()
        }
    }

    private static func value(_ rest: inout ArraySlice<String>) -> String {
        guard let value = rest.popFirst(), !value.isEmpty else { usage() }
        return value
    }
}

/// The CLI's wording for a daemon update report (#609): fixed tokens and counts only.
enum NotifyText {
    static let usage = """
           haild notify <target-id> --say <text> [--action] [--card <text>] [--socket <path>]
           haild notify status|quiet on [--socket <path>]
      (connected session updates; needs `haild run ... --personal-terminal --session-updates`)
    """

    static func lines(_ report: LocalSessionUpdateReport) -> [String] {
        let waiting = "\(report.held) update\(report.held == 1 ? "" : "s") waiting"
        switch report.outcome {
        case .delivered: return ["delivered: update card sent", "held: \(waiting)"] + speechLines(report)
        case .dropped: return ["dropped: \(report.reason ?? "private")", "held: \(waiting)"]
        case .held:
            var lines = ["held: \(waiting)"]
            if report.push { lines.append("push: unavailable (APNs delivery is not configured)") }
            return lines + speechLines(report)
        case .refused:
            var line = "refused: \(report.reason ?? "no reason given")"
            if let seconds = report.retryAfter { line += "; try again in \(seconds) s" }
            return [line]
        case .notEnabled: return ["not enabled: haild is running without --session-updates"]
        case .status: return ["held: \(waiting)", "quiet: \(report.quiet ? "on" : "off")"] + speechLines(report)
        }
    }

    private static func speechLines(_ report: LocalSessionUpdateReport) -> [String] {
        report.speechStatus.map { ["speech: \($0)"] } ?? []
    }

    static func exitCode(_ report: LocalSessionUpdateReport) -> Int32 {
        switch report.outcome {
        case .held, .status, .delivered, .dropped: 0
        case .refused: report.reason == "rate_limited" ? 75 : 1
        case .notEnabled: 1
        }
    }
}
