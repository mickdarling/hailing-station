#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// Configured PATH, full environment order, repository ancestry and workspace edge cases. Synthetic folders only.
extension CodexLaunchSetupTests {
    @Test func everyAllowlistedVariableKeepsItsFixedOrderAndNULValuesAreDropped() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = ["SHELL": "/bin/zsh", "TMPDIR": "/synthetic/tmp", "LANG": "C", "PATH": "/usr/bin",
                    "LOGNAME": "bad\0value", "USER": "synthetic", "HOME": "/Users/synthetic"]
        let setup = try CodexLaunchSetup.prepare(root: folder.path, host: host)
        #expect(setup.environment == ["HOME=/Users/synthetic", "USER=synthetic", "PATH=/usr/bin", "LANG=C",
                                      "TMPDIR=/synthetic/tmp", "SHELL=/bin/zsh"])
    }

    @Test func aConfiguredPathReplacesTheLaunchdPath() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = try CodexLaunchSetup.prepare(root: folder.path, path: "/opt/homebrew/bin:/usr/bin:/bin",
                                                 host: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(setup.environment == ["PATH=/opt/homebrew/bin:/usr/bin:/bin"])
    }

    @Test(arguments: ["", "relative/bin:/usr/bin", "/usr/bin::/bin", "/usr/bin:", "/usr/bin:.", "/bad\0bin"])
    func unsafeConfiguredPathsAreRefused(path: String) throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: CodexLaunchSetupError.invalidPath) {
            _ = try CodexLaunchSetup.prepare(root: folder.path, path: path, host: [:])
        }
    }

    @Test func aRootInsideAGitCheckoutIsRefused() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(atPath: folder.path + "/.git", withIntermediateDirectories: false)
        let nested = folder.path + "/codex"
        #expect(mkdir(nested, 0o700) == 0)
        #expect(throws: CodexLaunchSetupError.insideRepository) {
            _ = try CodexLaunchSetup.prepare(root: nested, host: [:])
        }
    }

    @Test func anExistingWorkspaceOthersCanReadIsRefused() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(mkdir(folder.path + "/workspace", 0o755) == 0)
        #expect(chmod(folder.path + "/workspace", 0o755) == 0)
        #expect(throws: CodexLaunchSetupError.unsafeOwnership) {
            _ = try CodexLaunchSetup.prepare(root: folder.path, host: [:])
        }
    }

    @Test func aHiddenFileMakesTheWorkspaceNonEmpty() throws {
        let folder = try Self.root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = try CodexLaunchSetup.prepare(root: folder.path, host: [:])
        try Data("invented".utf8).write(to: URL(fileURLWithPath: setup.workspace + "/.hidden"))
        #expect(throws: CodexLaunchSetupError.workspaceNotEmpty) {
            _ = try CodexLaunchSetup.prepare(root: folder.path, host: [:])
        }
    }
}
#endif
