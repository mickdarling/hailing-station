import Foundation
import Testing
@testable import HailDaemonKit
@testable import haild

/// `haild doctor`'s printed lines (#247): each check's mark, name and detail, its fix indented below. A `target_input`
/// warning (#894) is marked `WARN` with its fix and leaves the report healthy, so doctor exits 0. Synthetic report.
@Suite struct DoctorLinesTests {
    @Test func aWarningIsMarkedWarnWithItsFixAndTheReportStaysHealthy() {
        let report = HealthReport(
            cli: .init(version: "0.1.0", build: nil, hostID: nil), daemon: nil,
            checks: [
                HealthCheck(name: "daemon_running", outcome: .ok, detail: "pid 42"),
                HealthCheck(name: "target_input", outcome: .warn, detail: "last ambient request refused: inputPending",
                            fix: "synthetic flush fix")
            ]
        )
        #expect(report.healthy, "doctor exits 0")
        #expect(doctorLines(report) == [
            "ok    daemon_running  pid 42",
            "WARN  target_input    last ambient request refused: inputPending",
            "      fix: synthetic flush fix"
        ])
    }

    @Test func aFailureIsMarkedFailAndTheReportIsUnhealthy() {
        let report = HealthReport(
            cli: .init(version: "0.1.0", build: nil, hostID: nil), daemon: nil,
            checks: [HealthCheck(name: "device_connected", outcome: .fail, detail: "no device", fix: "connect one")]
        )
        #expect(!report.healthy, "doctor exits 1")
        #expect(doctorLines(report) == ["FAIL  device_connected  no device", "      fix: connect one"])
    }
}
