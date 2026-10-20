import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #614: a device asks for the host's health summary. Advertised and answered only with `--host-health` in personal
/// terminal mode; the answer carries known check names and outcomes, never the doctor's free text.
@Suite struct HostHealthSessionTests {
    static let base = ["--bind", "127.0.0.1", "--port", "4100"]
    static let report = HostHealth(version: "0.1.0", build: "0123456789abcdef", checks: [
        .init(name: "daemon_running", ok: true), .init(name: "listener_ready", ok: false)
    ])

    func capabilities(_ session: HostSession) async throws -> [String] {
        guard case .hello(let info) = try onlyControl(await session.receive(helloFrame())) else {
            throw TestSupportError.expectedOneControl
        }
        return info.capabilities
    }

    @Test func withASummaryTheCapabilityIsAdvertisedAndTheRequestAnswered() async throws {
        let (host, adapter) = try await sessionHost()
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(health: { Self.report }))
        #expect(try await capabilities(session).contains(HostHealth.capability))
        let result = await session.receive(sessionFrame(payload: .control(.health)))
        #expect(try onlyControl(result) == .healthReport(Self.report))
        #expect(result.disposition == .keepOpen)
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func anUnavailableSummaryIsARefusalThatKeepsTheConnection() async throws {
        let (host, _) = try await sessionHost()
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(health: { nil }))
        _ = try await capabilities(session)
        let result = await session.receive(sessionFrame(payload: .control(.health)))
        guard case .error(let code, _) = try onlyControl(result) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(code == .notAllowed && result.disposition == .keepOpen)
    }

    @Test func withoutASummaryNothingIsAdvertisedOrAnswered() async throws {
        let (host, _) = try await sessionHost()
        for authorizer in [PersonalTerminalAuthorizer(), ConnectionProbeAuthorizer()] as [any HostSessionAuthorizing] {
            let session = HostSession(host: host, authorizer: authorizer)
            #expect(try await !capabilities(session).contains(HostHealth.capability))
            let result = await session.receive(sessionFrame(payload: .control(.health)))
            guard case .error(let code, _) = try onlyControl(result) else {
                Issue.record("expected a refusal")
                return
            }
            #expect(code == .unauthorized && result.disposition == .keepOpen)
        }
    }

    @Test func theFlagIsOptInAndOnlyForThePersonalTerminal() throws {
        #expect(try ConnectionProbeDaemon.options(Self.base + ["--personal-terminal"]).health == false)
        #expect(try ConnectionProbeDaemon.options(Self.base + ["--personal-terminal", "--host-health"]).health)
        #expect(throws: WebSocketListenerError.invalidArguments) {
            try ConnectionProbeDaemon.options(Self.base + ["--connection-probe", "--host-health"])
        }
    }

    /// Only known names, each once; a build that is not a 16-hex digest is left off; detail and fix never carried.
    @Test func theSummaryKeepsOnlyWhatTheProtocolCarries() throws {
        let report = HealthReport(
            cli: .init(version: "0.1.0", build: "/Users/someone/haild", hostID: "host-a"), daemon: nil,
            checks: [
                .ok("daemon_running", "pid 42"), .fail("listener_ready", "127.0.0.1:8765 in use", fix: "restart"),
                .ok("daemon_running", "again"), .ok("a_future_check", "x")
            ]
        )
        let summary = try #require(HostHealthSummary.summary(of: report))
        #expect(summary == HostHealth(version: "0.1.0", build: nil, checks: [
            .init(name: "daemon_running", ok: true), .init(name: "listener_ready", ok: false)
        ]))
        let digest = HealthReport(cli: .init(version: "0.1.0", build: "0123456789abcdef", hostID: nil), daemon: nil,
                                  checks: [.ok("daemon_running", "pid 42")])
        #expect(HostHealthSummary.summary(of: digest)?.build == "0123456789abcdef")
        let empty = HealthReport(cli: .init(version: "0.1.0", build: nil, hostID: nil), daemon: nil,
                                 checks: [.ok("a_future_check", "x")])
        #expect(HostHealthSummary.summary(of: empty) == nil)
    }
}
