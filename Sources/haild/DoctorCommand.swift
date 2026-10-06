import Foundation
import HailDaemonKit

/// `haild status --json` and `haild doctor` (#247): the running daemon's snapshot compared with this CLI.
func healthReport() -> HealthReport {
    var refusals: RefusalSummary?
    var auditUnreadable = false
    do {
        refusals = try RefusalSummary.read(from: AuditHistory.standard())
    } catch AuditHistoryError.noHistory {
        refusals = nil
    } catch {
        auditUnreadable = true
    }
    return HealthReport.evaluate(
        cli: .init(version: DaemonInfo.version, build: BuildIdentity.current(), hostID: try? HostIdentity.resolve()),
        daemon: DaemonStatus.read(from: DaemonStatus.standardFile()),
        refusals: refusals, auditUnreadable: auditUnreadable
    )
}

/// Always exits 0 once a report is printed, so scripts read the `healthy` field rather than the exit code.
func statusJSON() throws {
    let data = try JSONEncoder.hailStatus.encode(healthReport())
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// Exits 1 when any check fails, with a plain-language fix under each failure.
func doctor() -> Never {
    let report = healthReport()
    print(DaemonInfo.banner)
    let width = report.checks.map(\.name.count).max() ?? 0
    for check in report.checks {
        let mark = check.outcome == .ok ? "ok  " : "FAIL"
        print("\(mark)  \(check.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(check.detail)")
        if let fix = check.fix { print("      fix: \(fix)") }
    }
    exit(report.healthy ? 0 : 1)
}
