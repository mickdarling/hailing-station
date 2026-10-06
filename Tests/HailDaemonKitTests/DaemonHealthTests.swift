import Foundation
import Testing
@testable import HailDaemonKit

/// `haild doctor` and `status --json` (#247): each failure seen on 2026-10-03/04 maps to one check.
@Suite struct DaemonHealthTests {
    private let cli = HealthReport.CLI(version: "0.1.0", build: "aaaaaaaaaaaaaaaa", hostID: "themachine.local")

    private func daemon(
        build: String? = "aaaaaaaaaaaaaaaa", hostID: String = "themachine.local",
        listener: DaemonStatus.Listener = .init(state: "ready", endpoint: "127.0.0.1:18765"), sessions: Int = 1
    ) -> DaemonStatus {
        DaemonStatus(
            schema: DaemonStatus.currentSchema, version: "0.1.0", build: build, pid: 4242,
            startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), hostID: hostID,
            listener: listener, connectedSessions: sessions
        )
    }

    private func failures(_ report: HealthReport) -> [String] {
        report.checks.filter { $0.outcome == .fail }.map(\.name)
    }

    @Test func aHealthyDaemonPassesEveryCheck() {
        let report = HealthReport.evaluate(cli: cli, daemon: daemon(), isRunning: { _ in true })
        #expect(report.healthy)
        #expect(report.checks.map(\.name)
            == ["daemon_running", "build_match", "host_id_match", "listener_ready", "device_connected"])
    }

    @Test func noSnapshotOrADeadPidIsTheOnlyFailureReported() {
        let missing = HealthReport.evaluate(cli: cli, daemon: nil, isRunning: { _ in true })
        #expect(failures(missing) == ["daemon_running"] && missing.checks.count == 1)
        let dead = HealthReport.evaluate(cli: cli, daemon: daemon(), isRunning: { _ in false })
        #expect(failures(dead) == ["daemon_running"] && dead.checks.count == 1)
        let stopped = HealthReport.evaluate(
            cli: cli, daemon: daemon(listener: .init(state: "stopped")), isRunning: { _ in true }
        )
        #expect(failures(stopped) == ["daemon_running"])
    }

    @Test func buildSkewFailsWithTheRedeployFix() {
        let skewed = daemon(build: "bbbbbbbbbbbbbbbb")
        let report = HealthReport.evaluate(cli: cli, daemon: skewed, isRunning: { _ in true })
        #expect(failures(report) == ["build_match"])
        #expect(report.checks[1].fix?.contains("scripts/host.sh deploy") == true)
        let unknown = HealthReport.evaluate(cli: cli, daemon: daemon(build: nil), isRunning: { _ in true })
        #expect(failures(unknown) == ["build_match"])
    }

    @Test func hostNameMismatchNamesSourceHostMismatch() {
        let report = HealthReport.evaluate(cli: cli, daemon: daemon(hostID: "dhcp-42.lan"), isRunning: { _ in true })
        #expect(failures(report) == ["host_id_match"])
        #expect(report.checks[2].fix?.contains("sourceHostMismatch") == true)
        let unresolved = HealthReport.CLI(version: "0.1.0", build: cli.build, hostID: nil)
        #expect(failures(HealthReport.evaluate(cli: unresolved, daemon: daemon(), isRunning: { _ in true }))
            == ["host_id_match"])
    }

    @Test func aPortHeldElsewherePointsAtTheServePortFix() {
        let failed = DaemonStatus.Listener(
            state: "failed", detail: "POSIXErrorCode(rawValue: 48): Address already in use"
        )
        let report = HealthReport.evaluate(cli: cli, daemon: daemon(listener: failed), isRunning: { _ in true })
        #expect(failures(report) == ["listener_ready"])
        #expect(report.checks[3].fix?.contains("Tailscale Serve") == true)
        let waiting = HealthReport.evaluate(
            cli: cli, daemon: daemon(listener: .init(state: "waiting", detail: "no route")), isRunning: { _ in true }
        )
        #expect(waiting.checks[3].fix?.contains("haild.err.log") == true)
    }

    @Test func noConnectedDeviceFails() {
        let report = HealthReport.evaluate(cli: cli, daemon: daemon(sessions: 0), isRunning: { _ in true })
        #expect(failures(report) == ["device_connected"])
    }

    @Test func theReportEncodesItsHealthyField() throws {
        let report = HealthReport.evaluate(cli: cli, daemon: daemon(sessions: 0), isRunning: { _ in true })
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.hailStatus.encode(report)) as? [String: Any]
        #expect(json?["healthy"] as? Bool == false)
        #expect(try JSONDecoder.hailStatus.decode(HealthReport.self, from: JSONEncoder.hailStatus.encode(report))
            == report)
    }

    @Test func thisProcessIsRunningAndPidZeroIsNot() {
        #expect(HealthReport.processIsRunning(ProcessInfo.processInfo.processIdentifier))
        #expect(!HealthReport.processIsRunning(0))
    }
}
