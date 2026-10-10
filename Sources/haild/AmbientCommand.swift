import Darwin
import Foundation
import HailDaemonKit

/// `haild ambient reload|status [--socket <path>]` (#405): asks the running daemon, over its owner-only reply socket,
/// to restart the active ambient stream's RightyO child (so a new install takes effect) or to describe it. Local
/// only: it never starts listening and never touches the phone. Prints one plain line per fact, never transcript
/// text. Exit 0 for `reloaded`, `idle` and any status; 75 for `busy` or `stopping` (try again); 1 otherwise.
func ambient(_ arguments: ArraySlice<String>) async throws {
    var rest = arguments
    guard let action = rest.popFirst().flatMap(LocalAmbientRequest.Action.init(rawValue:)) else { usage() }
    var socket = LocalReplyEndpoint.standardSocket()
    while let flag = rest.popFirst() {
        guard flag == "--socket", let value = rest.popFirst(), !value.isEmpty else { usage() }
        socket = URL(fileURLWithPath: value)
    }
    var line = try JSONEncoder().encode(LocalAmbientRequest(action: action))
    line.append(UInt8(ascii: "\n"))
    let response: LocalReplyResponse
    do {
        response = try await ReplyClient.transact(line, socketURL: socket)
    } catch ReplyClientError.unanswered(let why) {
        // Sent, but no answer (or one this haild cannot read): whether a reload happened is unknown.
        fail("unknown: no answer from the daemon after the request was sent (\(why)); run `haild ambient status`")
    }
    guard let report = response.ambient else {
        // Only a missing reason or a decode failure points at a daemon older than #409 (which reads this line as a
        // reply frame); a rate limit or audit failure is the current daemon's own refusal, given as is.
        guard let error = response.error, response.code != .decodeFailure else {
            fail("refused: \(response.error ?? "no ambient report") (the daemon may predate `haild ambient`;"
                 + " run `haild doctor`)")
        }
        fail("refused: \(error)")
    }
    for output in AmbientReportText.lines(report) { print(output) }
    exit(AmbientReportText.exitCode(report.outcome))
}

/// The CLI's wording for a daemon report (#405): fixed tokens, ids, times and counts only.
enum AmbientReportText {
    static func lines(_ report: LocalAmbientReport) -> [String] {
        switch report.outcome {
        case .reloaded:
            return ["reloaded: a fresh RightyO child serves the active stream (a second or so of audio around the"
                    + " restart may be lost)"]
        case .idle: return ["idle: no active ambient stream; nothing started"]
        case .busy: return ["busy: the daemon is busy with this stream (starting, reloading or stopping a child);"
                            + " try again in a few seconds"]
        case .stopping: return ["stopping: the daemon is shutting down"]
        case .refused: return ["refused: \(report.reason ?? "no reason given"); the running child keeps the stream"]
        case .notEnabled: return ["not enabled: haild is running without --ambient-rightyo"]
        case .status: return status(report)
        }
    }

    static func exitCode(_ outcome: LocalAmbientReport.Outcome) -> Int32 {
        switch outcome {
        case .reloaded, .idle, .status: 0
        case .busy, .stopping: 75
        case .refused, .notEnabled: 1
        }
    }

    private static func status(_ report: LocalAmbientReport) -> [String] {
        var lines = ["active: \(report.active ? "yes" : "no")"]
        if report.active { lines.append("device: \(report.deviceClass ?? "unknown")") }
        if let target = report.target { lines.append("target: \(target)") }
        if let since = report.since { lines.append("since: \(stamp(since))") }
        if let child = report.childSince { lines.append("child since: \(stamp(child))") }
        if let installed = report.installedAt {
            var text = "installed: \(stamp(installed))"
            if let child = report.childSince, installed > child {
                text += " (newer than the running child; run `haild ambient reload`)"
            }
            lines.append(text)
        }
        lines.append("live children: \(report.liveChildren)")
        return lines
    }

    /// Local time with its offset, to the second.
    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
