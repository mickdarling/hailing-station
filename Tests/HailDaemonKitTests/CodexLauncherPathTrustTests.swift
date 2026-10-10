#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// Ancestor folder trust: mode bits and ACL entries above the binary's own folder. Synthetic, `/bin/ls` copies.
extension CodexLauncherTests {
    /// `scratch/outer/inner/codex`, with `inner` and the copy private. `outer` is `folder/outer`.
    static func nested() throws -> (folder: URL, copy: String) {
        let folder = try scratch()
        let inner = folder.appendingPathComponent("outer/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let copy = inner.appendingPathComponent("codex").path
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy)
        guard chmod(copy, 0o700) == 0, chmod(inner.path, 0o700) == 0 else { throw CodexLaunchError.invalidPath }
        return (folder, copy)
    }
    static func addACL(_ entry: String, to path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", entry, path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CodexLaunchError.invalidPath }
    }

    @Test(arguments: [0o770, 0o707]) func aGroupOrWorldWritableAncestorIsRefused(mode: Int) async throws {
        let (folder, copy) = try Self.nested(), outer = folder.appendingPathComponent("outer").path
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(chmod(outer, mode_t(mode)) == 0)
        await #expect(throws: CodexLaunchError.unsafeOwnership) {
            _ = try await CodexLauncher.verify(path: copy, requirement: Self.apple, probe: Self.fixed(""))
        }
    }

    @Test(arguments: ["everyone allow add_subdirectory,delete_child", "everyone allow add_file",
                      "everyone allow writesecurity"])
    func anAncestorACLThatAllowsChangesIsRefused(entry: String) async throws {
        let (folder, copy) = try Self.nested(), outer = folder.appendingPathComponent("outer").path
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(chmod(outer, 0o700) == 0)
        try Self.addACL(entry, to: outer)
        await #expect(throws: CodexLaunchError.unsafeOwnership) {
            _ = try await CodexLauncher.verify(path: copy, requirement: Self.apple, probe: Self.fixed(""))
        }
    }

    @Test func anAncestorDenyACLIsAccepted() async throws {
        let (folder, copy) = try Self.nested(), outer = folder.appendingPathComponent("outer").path
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(chmod(outer, 0o700) == 0)
        try Self.addACL("everyone deny delete", to: outer)
        let evidence = try await CodexLauncher.verify(path: copy, requirement: Self.apple,
                                                      probe: Self.fixed("codex-cli 0.162.0-alpha.17.2\n"))
        #expect(evidence.version == "0.162.0-alpha.17.2")
    }
}
#endif
