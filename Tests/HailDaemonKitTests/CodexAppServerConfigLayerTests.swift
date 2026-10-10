#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// `config/read` evidence before any thread exists, with the invented App Server child.
@Suite struct CodexAppServerConfigLayerTests {
    @Test(arguments: [
        ("[{name=>{type=>'user'}},{name=>{type=>'system'}}]", "accepted"),
        ("[]", "accepted"),
        ("[{name=>{type=>'mdm'}},{name=>{type=>'sessionFlags'}},{name=>{type=>'packagedDefaults'}}]", "accepted"),
        ("[{name=>{type=>'user'}},{name=>{type=>'project',dotCodexFolder=>'/synthetic/.codex'}}]", "notIsolated"),
        ("[{name=>{type=>'user'}},{name=>{type=>'inventedFutureLayer'}}]", "notIsolated"),
        ("undef", "invalidProtocol"),
        ("[{name=>{}}]", "invalidProtocol")
    ])
    func projectLayersRefuseTheSessionBeforeAnyThread(layers: String, outcome: String) async throws {
        let command = CodexAppServerFixtures.command(configLayers: layers)
        let start = { try await CodexStdioTransport.withTransport(command: command) {
            try await CodexAppServerProtocol.start($0, workspace: "/synthetic-workspace")
        } }
        switch outcome {
        case "accepted": #expect(try await start() == "synthetic-thread")
        case "notIsolated": await #expect(throws: CodexAppServerError.notIsolated) { _ = try await start() }
        default: await #expect(throws: CodexAppServerError.invalidProtocol) { _ = try await start() }
        }
    }
}
#endif
