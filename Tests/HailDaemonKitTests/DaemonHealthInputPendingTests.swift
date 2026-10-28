import Foundation
import Testing
@testable import HailDaemonKit

/// #894: `haild doctor` names an ambient request the target refused because its input already holds unsent text, as an
/// advisory warning that points at the flush, and at a restart for a taint; haild stays healthy and doctor exits 0. It
/// reads only the status snapshot's last ambient event, which holds neither the target nor the adapter's reason, so the
/// fix names neither. Synthetic snapshots only.
@Suite struct DaemonHealthInputPendingTests {
    private let cli = HealthReport.CLI(version: "0.1.0", build: "aaaaaaaaaaaaaaaa", hostID: "themachine.local")

    private func report(_ event: String?, _ detail: String? = nil, at: Date? = nil) -> HealthReport {
        var status = DaemonStatus(
            schema: DaemonStatus.currentSchema, version: "0.1.0", build: "aaaaaaaaaaaaaaaa", pid: 4242,
            startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            hostID: "themachine.local", listener: .init(state: "ready", endpoint: "127.0.0.1:18765"),
            connectedSessions: 1
        )
        status.ambient = .init(enabled: true, running: 1, lastEvent: event, lastEventAt: at, lastDetail: detail)
        return HealthReport.evaluate(cli: cli, daemon: status, isRunning: { _ in true })
    }

    @Test func aRequestRefusedForPendingInputPointsAtTheFlushAndATaintsRestart() throws {
        let refused = report("ambient_delivery_refused", "reason=inputPending shown=sent confirm=no_clips")
        // A warning, never a failure: the report stays healthy, so `haild doctor` exits 0 (it exits 1 only when not).
        #expect(refused.healthy)
        #expect(refused.checks.filter { $0.outcome != .ok }.map(\.name) == ["target_input"])
        // The run goes on, so listening itself passes; the new check comes right after it.
        #expect(refused.checks.map(\.name) == [
            "daemon_running", "build_match", "host_id_match", "listener_ready", "ambient_listening", "target_input",
            "device_connected"
        ])
        let check = try #require(refused.checks.first { $0.name == "target_input" })
        #expect(check.outcome == .warn && check.detail == "ambient request refused: inputPending")
        let fix = try #require(check.fix)
        #expect(fix.contains("haild targets flush <target-id>"))
        #expect(fix.contains("if ~/Library/Logs/HailingStation/haild.err.log shows tmux_input_pending reason=tainted, "
            + "run scripts/host.sh restart"))
        // `status --json` keeps its shape: the check's outcome is `warn` and `healthy` stays true.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.hailStatus.encode(refused)) as? [String: Any]
        #expect(json?["healthy"] as? Bool == true)
        let checks = try #require(json?["checks"] as? [[String: Any]])
        #expect(checks.first { $0["name"] as? String == "target_input" }?["outcome"] as? String == "warn")
        #expect(try JSONDecoder.hailStatus.decode(HealthReport.self, from: JSONEncoder.hailStatus.encode(refused))
            == refused)
    }

    @Test func theWarningSaysHowLongAgoTheRefusalWas() throws {
        // A short-lived advisory either way: its age shows whether it predates a flush. Whole minutes, no content.
        let refused = report("ambient_delivery_refused", "reason=inputPending", at: Date().addingTimeInterval(-630))
        let check = try #require(refused.checks.first { $0.name == "target_input" })
        #expect(check.detail == "ambient request, 10 min ago, refused: inputPending")
        let future = report("ambient_delivery_refused", "reason=inputPending", at: Date().addingTimeInterval(600))
        // A clock that moved back never shows a negative age.
        #expect(future.checks.first { $0.name == "target_input" }?.detail
            == "ambient request, 0 min ago, refused: inputPending")
    }

    @Test func aWarningAlongsideAFailureLeavesTheReportUnhealthy() {
        var status = DaemonStatus(
            schema: DaemonStatus.currentSchema, version: "0.1.0", build: "bbbbbbbbbbbbbbbb", pid: 4242,
            startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            hostID: "themachine.local", listener: .init(state: "ready"), connectedSessions: 1
        )
        status.ambient = .init(enabled: true, lastEvent: "ambient_delivery_refused", lastDetail: "reason=inputPending")
        let report = HealthReport.evaluate(cli: cli, daemon: status, isRunning: { _ in true })
        #expect(!report.healthy)
        #expect(report.checks.filter { $0.outcome == .fail }.map(\.name) == ["build_match"])
        #expect(report.checks.filter { $0.outcome == .warn }.map(\.name) == ["target_input"])
    }

    @Test func anyOtherLastAmbientEventAddsNoInputCheck() {
        let others: [(String?, String?)] = [
            (nil, nil),
            ("ambient_acknowledged", "key=ack/0"),
            ("ambient_delivery_refused", "reason=deliveryRefused shown=sent confirm=no_clips"),
            ("ambient_delivery_refused", nil),
            ("ambient_voice_route_refused", "notDelivered shown=sent confirm=no_clips"),
            ("ambient_ended", "dispatch deliveryRefused")
        ]
        for (event, detail) in others {
            #expect(!report(event, detail).checks.contains { $0.name == "target_input" }, "\(event ?? "nil")")
        }
    }
}
