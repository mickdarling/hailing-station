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

/// Always exits 0 once printed: scripts read `healthy` for failures and each check's `outcome` for warnings.
func statusJSON() throws {
    let data = try JSONEncoder.hailStatus.encode(healthReport())
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// Exits 1 when any check fails, with a plain-language fix under each failure or warning; warnings alone exit 0.
func doctor() -> Never {
    let report = healthReport()
    print(DaemonInfo.banner)
    doctorLines(report).forEach { print($0) }
    exit(report.healthy ? 0 : 1)
}

/// One line per check, marked `ok`, `WARN` (advisory, #894) or `FAIL`, with its fix, if any, indented below it.
func doctorLines(_ report: HealthReport) -> [String] {
    let width = report.checks.map(\.name.count).max() ?? 0
    return report.checks.flatMap { check in
        let mark = switch check.outcome {
        case .ok: "ok  "
        case .warn: "WARN"
        case .fail: "FAIL"
        }
        let line = "\(mark)  \(check.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(check.detail)"
        return [line] + (check.fix.map { ["      fix: \($0)"] } ?? [])
    }
}
