import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// Live status reads memory through the existing owner-only socket, without policy or audit file I/O.
@Suite(.serialized, .frozenGuardBudget) struct LocalVoiceGuardsStatusTests {
    @Test(arguments: VoiceGuards.allCases)
    func effectivePolicyStaysInMemoryUntilReload(_ setting: VoiceGuards) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-vg-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PolicyFile(directory: directory)
        try file.save(Policy(voiceGuards: setting))
        let host = try HailHost(registry: Registry(), store: file)
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host)
        let audit = directory.appendingPathComponent("audit")
        let socket = directory.appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: listener, audit: AuditLog(directory: audit)
        )
        try await endpoint.start()
        do {
            let expected = LocalVoiceGuardsReport(value: setting == .on ? .on : .off, enforced: true)
            #expect(try await query(socket).voiceGuards == expected)
            try file.save(Policy(voiceGuards: setting == .on ? .off : .on))
            #expect(try await query(socket).voiceGuards == expected)
            try Data(#"{"version":1,"voiceGuards":null}"#.utf8).write(to: file.path)
            #expect(try await query(socket).voiceGuards == expected)
            #expect(await host.refreshedPolicy() == nil)
            #expect(try await query(socket).voiceGuards == .init(value: .unusable, enforced: true))
            #expect(!FileManager.default.fileExists(atPath: audit.path))
            try file.save(Policy(voiceGuards: .on))
            #expect(await host.refreshedPolicy() != nil)
            #expect(try await query(socket).voiceGuards == .init(value: .on, enforced: true))
            try await checkSharedSocket(socket)
            await endpoint.stop()
        } catch {
            await endpoint.stop()
            throw error
        }
    }

    private func query(_ socket: URL) async throws -> LocalReplyResponse {
        try await submit(Data(#"{"kind":"voice-guards","action":"status"}"#.utf8), socket: socket.path)
    }

    private func checkSharedSocket(_ socket: URL) async throws {
        let directoryInfo = try #require(try PolicyFile.info(socket.deletingLastPathComponent()))
        let socketInfo = try #require(try PolicyFile.info(socket))
        #expect(directoryInfo.st_uid == getuid())
        #expect(directoryInfo.st_mode & 0o777 == 0o700)
        #expect(socketInfo.st_uid == getuid())
        #expect(socketInfo.st_mode & 0o777 == 0o600)
        let ambient = try await submit(Data(#"{"kind":"ambient","action":"status"}"#.utf8), socket: socket.path)
        #expect(ambient.ambient?.outcome == .notEnabled)
        #expect(ambient.voiceGuards == nil)
        let update = try await submit(Data(#"{"kind":"update","action":"status"}"#.utf8), socket: socket.path)
        #expect(update.update?.outcome == .notEnabled)
        #expect(update.voiceGuards == nil)
        let progress = try await submit(Data(#"{"kind":"task_progress","action":"status"}"#.utf8), socket: socket.path)
        #expect(progress.progress?.outcome == "not_enabled")
        #expect(progress.voiceGuards == nil)
        for request in [#"{"kind":"voice-guards","action":"reload"}"#,
                        #"{"kind":"voice-guards","action":"status","extra":true}"#] {
            #expect(try await submit(Data(request.utf8), socket: socket.path).code == .decodeFailure)
        }
    }

    @Test func otherResponsesOmitTheEffectiveSetting() async throws {
        let encoded = try JSONEncoder().encode(LocalReplyResponse(delivered: 0))
        #expect(try #require(String(data: encoded, encoding: .utf8)).contains("voiceGuards") == false)
        #expect(try JSONDecoder().decode(LocalReplyResponse.self, from: encoded).voiceGuards == nil)
    }
}
