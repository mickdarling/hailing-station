#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// Synthetic only: scratch folders, an injected host environment and the invented App Server child.
@Suite struct CodexLaunchSetupTests {
    static func root(mode: mode_t = 0o700) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-setup-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        guard chmod(folder.path, mode) == 0 else { throw CodexLaunchSetupError.invalidRoot }
        return folder
    }
    private static let host = ["HOME": "/Users/synthetic", "PATH": "/opt/synthetic/bin:/usr/bin", "LANG": "en_US.UTF-8",
                               "OPENAI_API_KEY": "invented-secret", "SSH_AUTH_SOCK": "/synthetic/agent",
                               "CODEX_HOME": "/synthetic/elsewhere", "DYLD_INSERT_LIBRARIES": "/synthetic.dylib"]

    @Test func onlyAllowlistedVariablesReachTheChildInAFixedOrder() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = try CodexLaunchSetup.prepare(root: folder.path, host: Self.host)
        #expect(setup.environment == ["HOME=/Users/synthetic", "PATH=/opt/synthetic/bin:/usr/bin", "LANG=en_US.UTF-8"])
        #expect(setup.configOverrides.isEmpty)
    }

    @Test func theWorkspaceIsCreatedPrivateAndEmpty() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = try CodexLaunchSetup.prepare(root: folder.path, host: [:])
        var info = stat()
        #expect(lstat(setup.workspace, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(setup.workspace.hasSuffix("/workspace") && setup.workspace.hasPrefix("/"))
        #expect(try CodexLaunchSetup.prepare(root: folder.path, host: [:]) == setup)
    }

    @Test func aNonEmptyWorkspaceIsRefused() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = try CodexLaunchSetup.prepare(root: folder.path, host: [:])
        try Data("invented".utf8).write(to: URL(fileURLWithPath: setup.workspace + "/AGENTS.md"))
        #expect(throws: CodexLaunchSetupError.workspaceNotEmpty) {
            _ = try CodexLaunchSetup.prepare(root: folder.path, host: [:])
        }
    }

    @Test func aSymlinkedWorkspaceIsRefused() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/workspace", withDestinationPath: "/tmp")
        #expect(throws: CodexLaunchSetupError.invalidRoot) { _ = try CodexLaunchSetup.prepare(root: folder.path) }
    }

    @Test func aRootOthersCanReadIsRefused() throws {
        let folder = try Self.root(mode: 0o750)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: CodexLaunchSetupError.unsafeOwnership) { _ = try CodexLaunchSetup.prepare(root: folder.path) }
    }

    @Test(arguments: ["relative/root", "", "/nonexistent-synthetic-root"])
    func invalidRootsAreRefused(root: String) {
        #expect(throws: CodexLaunchSetupError.invalidRoot) { _ = try CodexLaunchSetup.prepare(root: root) }
    }

    @Test func disabledServersBecomeExactPerLaunchOverrides() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = try CodexLaunchSetup.prepare(root: folder.path, disabledServers: ["chief", "cloud_api-2"],
                                                 host: [:])
        #expect(setup.configOverrides == ["-c", "mcp_servers.chief.enabled=false",
                                          "-c", "mcp_servers.cloud_api-2.enabled=false"])
    }

    @Test(arguments: ["", "a.b", "x=true", "name with space", "quote\"", String(repeating: "a", count: 65)])
    func unsafeServerNamesAreRefused(name: String) throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: CodexLaunchSetupError.invalidServerName) {
            _ = try CodexLaunchSetup.prepare(root: folder.path, disabledServers: [name], host: [:])
        }
    }

    @Test func threadStartSendsTheWorkspaceAndRefusesADifferentCwd() async throws {
        let echoed = try await CodexStdioTransport.withTransport(command: CodexAppServerFixtures.command()) {
            try await CodexAppServerProtocol.start($0, workspace: "/synthetic-workspace")
        }
        #expect(echoed == "synthetic-thread")
        let command = CodexAppServerFixtures.command(echoedCwd: "/synthetic-elsewhere")
        await #expect(throws: CodexAppServerError.invalidProtocol) {
            _ = try await CodexStdioTransport.withTransport(command: command) {
                try await CodexAppServerProtocol.start($0, workspace: "/synthetic-workspace")
            }
        }
    }
}
#endif
