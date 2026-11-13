import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ReplyMaskingCompatibilityTests {
    private static func diagnostics(_ socket: ScriptedSocket) async throws -> [DiagnosticEvent] {
        try await socket.sentFrames().flatMap { frame -> [DiagnosticEvent] in
            guard case .control(.diagnostic(let events)) = frame.payload else { return [] }
            return events
        }
    }

    @Test(arguments: [false, true])
    func onlyAdvertisingHostsReceiveMaskingFieldsAndTokens(accepts: Bool) async throws {
        let host = try endpoint(), socket = ScriptedSocket(), connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: host.url)
        let connection = HostConnection(endpoint: host, connector: connector)
        await connection.connect()
        try await waitUntil { try await socket.sentFrames().count == 1 }
        let capabilities = ["ping", DiagnosticLimits.capability]
            + (accepts ? [DiagnosticLimits.replyMaskingCapability] : [])
        try await socket.push(.hello(HelloInfo(versions: [1], capabilities: capabilities, deviceName: "Mac")))
        try await waitUntil { await connection.snapshot.state == .ready }
        let legacy = [
            try DiagnosticEvent(.echoGuard, timestamp: 1, fields: [.on: .boolean(true)]),
            try DiagnosticEvent(.echoGuard, timestamp: 2, fields: [.on: .boolean(false), .ms: .integer(400)])
        ]
        let mode = try DiagnosticEvent(.captureState, timestamp: 1, fields: [.capture: .token("plain")])
        let edges = [mode] + (try DiagnosticLimits.replyMaskingReasons.flatMap { reason in
            try [true, false].map { masking in
                try DiagnosticEvent(.echoGuard, timestamp: 1, fields: [
                    .masking: .boolean(masking), .reason: .token(reason), .capture: .token("plain")
                ])
            }
        })
        try await connection.sendDiagnostics(legacy + edges)
        let sent = try await Self.diagnostics(socket)
        #expect(sent == (accepts ? legacy + edges : legacy))
        let before = sent.count
        try await connection.sendDiagnostics(edges)
        #expect(try await Self.diagnostics(socket).count
                == before + (accepts ? edges.count : 0))
        await connection.disconnect()
    }
}
