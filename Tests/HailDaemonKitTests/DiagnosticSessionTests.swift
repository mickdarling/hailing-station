import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Session wiring for device diagnostics (#234): advertised and accepted only with a sink, stored without a
/// reply, and never a change to selection or delivery.
@Suite struct DiagnosticSessionTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-diagnostic-session-\(UUID().uuidString)", isDirectory: true)
    static let base = ["--bind", "127.0.0.1", "--port", "4100"]

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    func capabilities(_ session: HostSession) async throws -> [String] {
        guard case .hello(let info) = try onlyControl(await session.receive(helloFrame())) else {
            throw TestSupportError.expectedOneControl
        }
        return info.capabilities
    }

    @Test func withASinkTheCapabilityIsAdvertisedAndEventsAreStoredSilently() async throws {
        defer { cleanUp() }
        let (host, adapter) = try await sessionHost()
        let log = DiagnosticLog(directory: scratch)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(diagnostics: log))
        #expect(try await capabilities(session).contains(DiagnosticLimits.capability))
        let frame = sessionFrame(payload: .control(.diagnostic(events: try diagnosticEvents(2))))
        let result = await session.receive(frame)
        #expect(result == HostSessionResult(frames: []))
        let text = try String(contentsOf: scratch.appendingPathComponent(DiagnosticLog.fileName), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.contains("\"device\":\"test\""))
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func withoutASinkNothingIsAdvertisedAcceptedOrWritten() async throws {
        defer { cleanUp() }
        let (host, _) = try await sessionHost()
        for authorizer in [PersonalTerminalAuthorizer(), ConnectionProbeAuthorizer()] as [any HostSessionAuthorizing] {
            let session = HostSession(host: host, authorizer: authorizer)
            #expect(try await !capabilities(session).contains(DiagnosticLimits.capability))
            let frame = sessionFrame(payload: .control(.diagnostic(events: try diagnosticEvents(1))))
            let result = await session.receive(frame)
            guard case .error(let code, _) = try onlyControl(result) else {
                Issue.record("expected a refusal")
                return
            }
            #expect(code == .unauthorized)
            #expect(result.disposition == .keepOpen)
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test func theFlagIsOptInAndOnlyForThePersonalTerminal() throws {
        #expect(try ConnectionProbeDaemon.options(Self.base + ["--personal-terminal"]).diagnostics == nil)
        let options = try ConnectionProbeDaemon.options(Self.base + ["--personal-terminal", "--device-diagnostics"])
        #expect(options.diagnostics?.lastPathComponent == "diagnostics")
        #expect(throws: WebSocketListenerError.invalidArguments) {
            try ConnectionProbeDaemon.options(Self.base + ["--connection-probe", "--device-diagnostics"])
        }
    }

    @Test func standardDirectoryFollowsTheConfigOverride() {
        let url = DiagnosticLog.standardDirectory(environment: ["HAIL_CONFIG_DIR": "/tmp/hail-config"])
        #expect(url.path == "/tmp/hail-config/diagnostics")
    }
}
