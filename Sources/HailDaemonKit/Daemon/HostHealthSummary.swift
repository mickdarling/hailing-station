import Foundation
public import HailProtocol

/// The `haild doctor` report (#247) reduced to what a device may see (#614): the release version, the build digest
/// and each known check's name and outcome. The detail and fix stay on the Mac (they can name paths, ports and
/// identities); the device points to `haild doctor` for them.
public enum HostHealthSummary {
    /// The doctor's evaluation as this daemon sees itself: its own build and host ID against its status file.
    @Sendable public static func current() async -> HostHealth? {
        var refusals: RefusalSummary?
        var auditUnreadable = false
        do {
            refusals = try RefusalSummary.read(from: AuditHistory.standard())
        } catch AuditHistoryError.noHistory {
            refusals = nil
        } catch {
            auditUnreadable = true
        }
        let report = HealthReport.evaluate(
            cli: .init(version: DaemonInfo.version, build: BuildIdentity.current(),
                       hostID: try? HostIdentity.resolve()),
            daemon: DaemonStatus.read(from: DaemonStatus.standardFile()),
            refusals: refusals, auditUnreadable: auditUnreadable
        )
        return summary(of: report)
    }

    /// Known check names only, each once, at most `HostHealth.maxChecks`; a build that is not a 16-hex digest is
    /// left off. Nil when nothing the protocol can carry remains.
    static func summary(of report: HealthReport) -> HostHealth? {
        var seen: Set<String> = []
        let checks = report.checks.compactMap { check -> HostHealth.Check? in
            guard let name = HostHealth.checkName(check.name), seen.insert(name).inserted else { return nil }
            return HostHealth.Check(name: name, ok: check.outcome == .ok)
        }.prefix(HostHealth.maxChecks)
        let build = (report.daemon?.build ?? report.cli.build).flatMap { build in
            build.count == 16 && build.allSatisfy { $0.isHexDigit && !$0.isUppercase } ? build : nil
        }
        let health = HostHealth(version: report.cli.version, build: build, checks: Array(checks))
        return (try? JSONEncoder().encode(health)) == nil ? nil : health
    }
}
