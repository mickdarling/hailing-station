import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct ReplyMaskingHostTests {
    @Test func capabilityRequiresAnEnabledDiagnosticsSink() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-masking")
        #expect(!PersonalTerminalAuthorizer().capabilities.contains(DiagnosticLimits.replyMaskingCapability))
        let authorizer = PersonalTerminalAuthorizer(diagnostics: DiagnosticLog(directory: dir))
        #expect(authorizer.capabilities.contains(DiagnosticLimits.replyMaskingCapability))
    }

    @Test func hostStoresOrderedContentFreeEdgesWithItsExistingSession() async throws {
        let rig = DiagnosticLogTests()
        defer { rig.cleanUp() }
        let log = DiagnosticLog(directory: rig.dir)
        let (host, adapter) = try await sessionHost()
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(diagnostics: log))
        let hello = try onlyControl(await session.receive(helloFrame()))
        guard case .hello(let info) = hello else {
            Issue.record("expected host hello")
            return
        }
        #expect(info.capabilities.contains(DiagnosticLimits.replyMaskingCapability))
        let edges = try [true, false].map { masking in
            try DiagnosticEvent(.echoGuard, timestamp: masking ? 1 : 401, fields: [
                .masking: .boolean(masking), .reason: .token("plain_capture"), .capture: .token("plain"),
                .count: .integer(1), .ms: .integer(masking ? 0 : 400)
            ])
        }
        let legacy = try DiagnosticEvent(.echoGuard, timestamp: 0, fields: [.on: .boolean(true)])
        let mode = try DiagnosticEvent(.captureState, timestamp: 0, fields: [.capture: .token("plain")])
        let events = [mode, legacy] + edges
        let wire = try FrameCoding.encode(sessionFrame(payload: .control(.diagnostic(events: events))))
        #expect(await session.receive(wire) == HostSessionResult(frames: []))
        let records = try rig.lines(rig.file)
        #expect(records.map(\.event) == events)
        #expect(Set(records.map(\.session)).count == 1)
        #expect(await adapter.deliveries.isEmpty)
    }
}
