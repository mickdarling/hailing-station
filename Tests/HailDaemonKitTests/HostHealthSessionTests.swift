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

    /// The doctor's check names and the protocol's list are kept in two places; this fails if they drift apart.
    /// `target_input` (#894) is the one doctor check kept on the Mac: a new name on the wire waits for a protocol
    /// change, so the summary leaves it off.
    @Test func everyDoctorCheckNameIsOneTheProtocolCarries() {
        let cli = HealthReport.CLI(version: "0.1.0", build: "aaaaaaaaaaaaaaaa", hostID: "h")
        let daemon = DaemonStatus(
            schema: DaemonStatus.currentSchema, version: "0.1.0", build: "aaaaaaaaaaaaaaaa", pid: 1,
            startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), hostID: "h",
            listener: .init(state: "ready", endpoint: "127.0.0.1:1"), connectedSessions: 1,
            ambient: .init(enabled: true, lastEvent: "ambient_delivery_refused", lastDetail: "reason=inputPending")
        )
        let every = HealthReport.evaluate(cli: cli, daemon: daemon,
                                          refusals: RefusalSummary.summarize([], now: Date()),
                                          auditUnreadable: true, isRunning: { _ in true })
        #expect(Set(every.checks.map(\.name)) == Set(HostHealth.checkNames + ["target_input"]))
        #expect(HostHealthSummary.summary(of: every).checks.map(\.name) == HostHealth.checkNames)
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
        let summary = HostHealthSummary.summary(of: report)
        #expect(summary == HostHealth(version: "0.1.0", build: nil, checks: [
            .init(name: "daemon_running", ok: true), .init(name: "listener_ready", ok: false)
        ]))
        let digest = HealthReport(cli: .init(version: "0.1.0", build: "0123456789abcdef", hostID: nil), daemon: nil,
                                  checks: [.ok("daemon_running", "pid 42")])
        #expect(HostHealthSummary.summary(of: digest).build == "0123456789abcdef")
        // ASCII hex only: full-width or other Unicode digits drop the build, never the report.
        let wide = HealthReport(cli: .init(version: "0.1.0", build: "０１２３４５６７８９abcdef", hostID: nil),
                                daemon: nil, checks: [.ok("daemon_running", "pid 42")])
        #expect(HostHealthSummary.summary(of: wide).build == nil)
        // Never empty: the daemon answering is itself running.
        let empty = HealthReport(cli: .init(version: "0.1.0", build: nil, hostID: nil), daemon: nil,
                                 checks: [.ok("a_future_check", "x")])
        #expect(HostHealthSummary.summary(of: empty).checks == [.init(name: "daemon_running", ok: true)])
    }

    #if os(macOS)
    /// With `--voice-routes` (#636) as well, the composed authorizer keeps both: health is wired before the routes are
    /// named, so rebuilding the authorizer for health never drops the owner's routes.
    @Test func hostHealthAndVoiceRoutesComposeTogether() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let routes = scratch.appendingPathComponent("routes.json")
        try Data(#"{"version": 1, "default": "tmux:a", "routes": [{"target": "tmux:a", "name": "A"}]}"#.utf8)
            .write(to: routes)
        var options = try ConnectionProbeDaemon.options(Self.base + [
            "--personal-terminal", "--reply-socket", scratch.appendingPathComponent(LocalReplyEndpoint.socketName).path,
            "--host-health", "--voice-routes", routes.path
        ])
        options.port = 0
        let rig = try await RecipientTestRig.make()
        let (listener, _) = try await ConnectionProbeDaemon.compose(
            options, host: rig.host, hostName: "mac-test",
            audit: AuditLog(directory: scratch.appendingPathComponent("audit", isDirectory: true)), log: { _ in }
        )
        let composed = await listener.authorizer
        let authorizer = try #require(composed as? PersonalTerminalAuthorizer)
        #expect(authorizer.health != nil && authorizer.capabilities.contains(HostHealth.capability))
        #expect(authorizer.voiceRoutes?.defaultTarget == "tmux:a")
    }
    #endif
}
