import Foundation
import HailDaemonKit

/// `haild diagnostics tail|show|clear` (#234): reads the device diagnostics log `haild run
/// --device-diagnostics` writes. Text output is one line per event; `--json` prints the stored records.
func diagnostics(_ arguments: ArraySlice<String>, now: Date = Date()) throws {
    guard let command = arguments.first else { usage() }
    let directory = DiagnosticLog.standardDirectory()
    var rest = arguments.dropFirst()
    switch command {
    case "clear":
        guard rest.isEmpty else { usage() }
        try DiagnosticLog.clear(directory: directory)
        print("cleared device diagnostics at \(directory.path)")
    case "tail":
        let options = diagnosticsTailOptions(&rest, now: now)
        try printDiagnostics(DiagnosticLog.records(in: directory, matching: options.query).suffix(options.limit),
                             json: options.json)
    case "show":
        guard let session = rest.popFirst(), session.count >= 4, !session.hasPrefix("-") else { usage() }
        let json = rest == ["--json"]
        guard rest.isEmpty || json else { usage() }
        try printDiagnostics(DiagnosticLog.records(in: directory, matching: .init(session: session))[...], json: json)
    default:
        usage()
    }
}

private struct DiagnosticsTailOptions {
    var query = DiagnosticQuery()
    var limit = 50
    var json = false
}

private func diagnosticsTailOptions(_ rest: inout ArraySlice<String>, now: Date) -> DiagnosticsTailOptions {
    var options = DiagnosticsTailOptions()
    while let flag = rest.popFirst() {
        switch flag {
        case "--json": options.json = true
        case "--device":
            guard let device = rest.popFirst() else { usage() }
            options.query.device = device
        case "--since":
            guard let value = rest.popFirst(), let since = diagnosticsSince(value, now: now) else { usage() }
            options.query.since = since
        case "--limit":
            guard let value = rest.popFirst(), let parsed = Int(value), parsed > 0 else { usage() }
            options.limit = parsed
        default: usage()
        }
    }
    return options
}

private func printDiagnostics(_ records: ArraySlice<DiagnosticRecord>, json: Bool) throws {
    for record in records {
        if json {
            print(try record.asciiJSON())
        } else {
            print(record.line)
        }
    }
    if records.isEmpty { note("no device diagnostics match (logging needs `haild run ... --device-diagnostics`)") }
}

/// `--since`: a relative age (`90s`, `15m`, `2h`, `1d`) or an ISO 8601 time, as milliseconds since 1970.
func diagnosticsSince(_ value: String, now: Date) -> Int64? {
    let units: [Character: Double] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
    if let unit = value.last, let scale = units[unit], let amount = Double(value.dropLast()),
       amount.isFinite, (0...1e9).contains(amount) {
        return Int64(((now.timeIntervalSince1970 - amount * scale) * 1_000).rounded(.down))
    }
    let formatter = ISO8601DateFormatter()
    let fractional: ISO8601DateFormatter.Options = [.withInternetDateTime, .withFractionalSeconds]
    for options in [fractional, [.withInternetDateTime]] {
        formatter.formatOptions = options
        if let date = formatter.date(from: value) { return Int64((date.timeIntervalSince1970 * 1_000).rounded(.down)) }
    }
    return nil
}
