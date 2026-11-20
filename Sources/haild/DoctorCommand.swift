import Foundation
import HailDaemonKit

/// `haild status --json` and `haild doctor` (#247): the running daemon's snapshot compared with this CLI.
func healthReport() async -> PolicyHealthReport {
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
    return PolicyHealthReport(health: health, store: PolicyFile.standard(), live: await liveVoiceGuards())
}

/// Always exits 0 once printed: scripts read `healthy` for failures and each check's `outcome` for warnings.
func statusJSON() async throws {
    let data = try JSONEncoder.hailStatus.encode(await healthReport())
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// Exits 1 when any check fails, with a plain-language fix under each failure or warning; warnings alone exit 0.
func doctor() async -> Never {
    let report = await healthReport()
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

/// The same bounded Unix-socket client used by ambient, notify and progress. No fallback to file defaults.
func liveVoiceGuards(socket: URL = LocalReplyEndpoint.standardSocket()) async -> LocalVoiceGuardsReport? {
    do {
        let line = Data(#"{"kind":"voice-guards","action":"status"}"#.utf8) + Data([10])
        let response = try await ReplyClient.transact(line, socketURL: socket)
        guard response.delivered == 0, response.error == nil, response.code == nil,
              !response.isDispatch, response.ambient == nil, response.update == nil,
              response.progress == nil else { return nil }
        return response.voiceGuards
    } catch {
        return nil
    }
}

func voiceGuardsDetail(_ live: LocalVoiceGuardsReport?) -> String {
    guard let live else { return "unknown (live daemon unavailable or invalid reply)" }
    switch live.value {
    case .on: return "on"
    case .off:
        return live.enforced ? "voice guard holds are off for voice requests" : "off (not enforced by this build)"
    case .unusable: return "unusable (running daemon policy failure)"
    }
}

func voiceGuardsMismatch(configured: String, live: LocalVoiceGuardsReport?) -> String? {
    guard let live, configured != live.value.rawValue else { return nil }
    return "policy file says \(configured); running daemon uses \(live.value.rawValue); reload pending"
}

/// CLI health compares the owner policy file with the effective policy returned by the live daemon.
struct PolicyHealthReport: Encodable {
    private let health: HealthReport
    var checks: [DoctorCheck]
    var healthy: Bool { checks.allSatisfy { $0.outcome != .fail } }
    let voiceGuards: LocalVoiceGuardsReport.Value?
    let configuredVoiceGuards: VoiceGuards?
    private let live: LocalVoiceGuardsReport?

    init(health: HealthReport, store: any PolicyStore, live: LocalVoiceGuardsReport?) {
        self.health = health
        voiceGuards = live?.value
        self.live = live
        checks = health.checks.map(DoctorCheck.init)
        do {
            configuredVoiceGuards = try store.load().voiceGuards
        } catch {
            configuredVoiceGuards = nil
            checks.append(DoctorCheck(
                name: "policy", outcome: .fail, detail: "policy unreadable or malformed; voice guards unknown",
                fix: "repair the owner policy file; delivery is refused while policy is unusable"
            ))
        }
        let outcome: HealthCheck.Outcome = live == nil || live?.value == .unusable ? .fail
            : (live?.value == .off ? .warn : .ok)
        checks.append(DoctorCheck(
            name: "voice_guards", outcome: outcome, detail: voiceGuardsDetail(live),
            fix: outcome == .fail ? "check the running daemon and local control socket; repair policy if unusable" : nil
        ))
        if let mismatch = voiceGuardsMismatch(configured: configuredVoiceGuards?.rawValue ?? "unusable", live: live) {
            checks.append(DoctorCheck(name: "voice_guards_policy", outcome: .warn, detail: mismatch))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cli, daemon, refusals, checks, healthy, voiceGuards, voiceGuardsEnforced, configuredVoiceGuards
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(health.cli, forKey: .cli)
        try container.encodeIfPresent(health.daemon, forKey: .daemon)
        try container.encodeIfPresent(health.refusals, forKey: .refusals)
        try container.encode(checks, forKey: .checks)
        try container.encode(healthy, forKey: .healthy)
        try container.encode(voiceGuards, forKey: .voiceGuards)
        try container.encode(live?.enforced, forKey: .voiceGuardsEnforced)
        try container.encode(configuredVoiceGuards, forKey: .configuredVoiceGuards)
    }
}
