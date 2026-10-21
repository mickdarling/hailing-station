import Foundation
import Testing
@testable import HailProtocol

/// #614: a device asks a host for its health summary and gets back a closed, bounded report: a version, a short
/// build digest and known check names with pass or fail, never the doctor's free text.
@Suite struct HostHealthProtocolTests {
    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }

    private func roundTrip(_ control: ControlPayload) throws {
        let frame = Frame(timestamp: 1, source: "host", payload: .control(control))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
    }

    @Test func theRequestAndAFullReportRoundTrip() throws {
        try roundTrip(.health)
        let every = HostHealth.checkNames.enumerated().map { HostHealth.Check(name: $1, ok: $0.isMultiple(of: 2)) }
        let report = HostHealth(version: "0.1.0", build: "0123456789abcdef", checks: every)
        try roundTrip(.healthReport(report))
        try roundTrip(.healthReport(HostHealth(version: "1.2.3-beta+4", build: nil,
                                               checks: [.init(name: "daemon_running", ok: true)])))
        #expect(!report.healthy)
        #expect(try decodeControl(#"{"command":"health"}"#) == .health)
    }

    private static let okCheck = #"{"name":"daemon_running","ok":true}"#

    /// A `health_report` payload with `report` set to the given object body.
    private static func report(_ body: String) -> String { #"{"command":"health_report","report":{"# + body + "}}" }

    @Test(arguments: [
        #"{"command":"health","target":"tmux:a"}"#, #"{"command":"health_report"}"#,
        report(#""version":"0.1.0","checks":[]"#),
        report(#""version":"","checks":["# + okCheck + "]"),
        report(#""version":"0.1.0 (Mick's Mac)","checks":["# + okCheck + "]"),
        report(#""version":"0.1.0","build":"0123456789ABCDEF","checks":["# + okCheck + "]"),
        report(#""version":"0.1.0","build":"0123","checks":["# + okCheck + "]"),
        report(#""version":"0.1.0","checks":[{"name":"Daemon_Running","ok":true}]"#),
        report(#""version":"0.1.0","checks":[{"name":"daemon_running","ok":"yes"}]"#),
        report(#""version":"0.1.0","checks":[{"name":"daemon_running","ok":true,"fix":"restart"}]"#),
        report(#""version":"0.1.0","host":"mac","checks":["# + okCheck + "]"),
        report(#""version":"0.1.0","checks":["# + okCheck + "," + okCheck + "]")
    ])
    func anythingOutsideTheShapeIsRefused(_ payload: String) {
        #expect(throws: DecodingError.self) { try decodeControl(payload) }
    }

    @Test func tooManyChecksAreRefused() throws {
        let checks = Array(repeating: Self.okCheck, count: HostHealth.maxChecks + 1).joined(separator: ",")
        #expect(throws: DecodingError.self) {
            try decodeControl(Self.report(#""version":"0.1.0","checks":["# + checks + "]"))
        }
    }

    @Test func anInvalidReportIsRefusedWhenEncodingToo() {
        let refused: [HostHealth] = [
            HostHealth(version: "0.1.0", build: nil, checks: [.init(name: "rightyo_path", ok: true)]),
            HostHealth(version: "0.1.0", build: "/tmp/haild", checks: [.init(name: "daemon_running", ok: true)]),
            HostHealth(version: "0.1.0", build: nil, checks: [])
        ]
        for report in refused {
            #expect(throws: EncodingError.self) {
                try FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(.healthReport(report))))
            }
        }
    }
}
