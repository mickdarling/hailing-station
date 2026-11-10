import Foundation
import HailDaemonKit

/// `haild status --json` and `haild doctor` (#247): the running daemon's snapshot compared with this CLI.
func healthReport() -> PolicyHealthReport {
    var refusals: RefusalSummary?
    var auditUnreadable = false
    do {
        refusals = try RefusalSummary.read(from: AuditHistory.standard())
    } catch AuditHistoryError.noHistory {
        refusals = nil
    } catch {
        auditUnreadable = true
    }
    let health = HealthReport.evaluate(
        cli: .init(version: DaemonInfo.version, build: BuildIdentity.current(), hostID: try? HostIdentity.resolve()),
        daemon: DaemonStatus.read(from: DaemonStatus.standardFile()),
        refusals: refusals, auditUnreadable: auditUnreadable
    )
    return PolicyHealthReport(health: health, store: PolicyFile.standard())
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
    doctorLines(report.checks.map(DoctorCheck.init))
}

func doctorLines(_ report: PolicyHealthReport) -> [String] { doctorLines(report.checks) }

private func doctorLines(_ checks: [DoctorCheck]) -> [String] {
    let width = checks.map(\.name.count).max() ?? 0
    return checks.flatMap { check in
        let mark = switch check.outcome {
        case .ok: "ok  "
        case .warn: "WARN"
        case .fail: "FAIL"
        }
        let line = "\(mark)  \(check.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(check.detail)"
        return [line] + (check.fix.map { ["      fix: \($0)"] } ?? [])
    }
}

/// CLI checks retain the shared health-check JSON shape and can add policy configuration diagnostics.
struct DoctorCheck: Encodable {
    let name: String
    let outcome: HealthCheck.Outcome
    let detail: String
    var fix: String?

    init(name: String, outcome: HealthCheck.Outcome, detail: String, fix: String? = nil) {
        self.name = name
        self.outcome = outcome
        self.detail = detail
        self.fix = fix
    }

    init(_ check: HealthCheck) {
        self.init(name: check.name, outcome: check.outcome, detail: check.detail, fix: check.fix)
    }
}

/// CLI health includes owner policy configuration, separate from the running daemon's snapshot.
/// An unreadable policy has an unknown (null) setting and a failing check, never an assumed default.
struct PolicyHealthReport: Encodable {
    private let health: HealthReport
    var checks: [DoctorCheck]
    var healthy: Bool { checks.allSatisfy { $0.outcome != .fail } }
    let voiceGuards: VoiceGuards?

    init(health: HealthReport, store: any PolicyStore) {
        self.health = health
        checks = health.checks.map(DoctorCheck.init)
        do {
            let policy = try store.load()
            voiceGuards = policy.voiceGuards
            if policy.voiceGuards == .off {
                checks.append(DoctorCheck(
                    name: "voice_guards", outcome: .warn, detail: "off in policy (not enforced by this build)"
                ))
            }
        } catch {
            voiceGuards = nil
            checks.append(DoctorCheck(
                name: "policy", outcome: .fail, detail: "policy unreadable or malformed; voice guards unknown",
                fix: "repair the owner policy file; delivery is refused while policy is unusable"
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cli, daemon, refusals, checks, healthy, voiceGuards, voiceGuardsEnforced
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(health.cli, forKey: .cli)
        try container.encodeIfPresent(health.daemon, forKey: .daemon)
        try container.encodeIfPresent(health.refusals, forKey: .refusals)
        try container.encode(checks, forKey: .checks)
        try container.encode(healthy, forKey: .healthy)
        try container.encode(voiceGuards, forKey: .voiceGuards)
        try container.encode(false, forKey: .voiceGuardsEnforced)
    }
}
