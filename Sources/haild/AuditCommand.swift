import HailDaemonKit

func audit(_ arguments: ArraySlice<String>) throws {
    guard arguments.count == 1, let command = arguments.first else { usage() }
    let history = AuditHistory.standard()
    switch command {
    case "verify":
        let report = try history.verify()
        var message = "verified \(report.days) day\(report.days == 1 ? "" : "s"), "
            + "\(report.records) record\(report.records == 1 ? "" : "s")"
        if let day = report.lastDay, let hash = report.lastHash { message += "; tail \(day) \(hash)" }
        print(message)
    case "tail":
        for line in try history.tail() { print(line) }
    case "today":
        for line in try history.today() { print(line) }
    default:
        usage()
    }
}
