#if os(macOS)
import Foundation

/// Fixed public-safe refusals: no path or variable value is echoed.
enum CodexLaunchSetupError: Error, Sendable, Equatable {
    case invalidRoot, unsafeOwnership, workspaceNotEmpty, invalidServerName
}

/// How the owned App Server child is started: the owner's normal Codex home and configuration (#153 design
/// revision), an allowlisted slice of the host environment, and an owned empty workspace as the thread's cwd.
struct CodexLaunchSetup: Sendable, Equatable {
    /// Enough for the CLI to find `~/.codex` and for the owner's MCP servers to find their tools. Keys, tokens,
    /// proxies and anything else in the host environment are not passed on.
    static let inheritedVariables = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "TMPDIR", "SHELL"]

    let workspace: String
    let environment: [String]
    /// Per-launch `-c` overrides that switch off named MCP servers from the owner's config for these sessions only.
    let configOverrides: [String]

    /// `root` comes from trusted host configuration. Creates `root/workspace` (0700) when missing; it must be
    /// a real, private, empty folder so no repository instructions or files are picked up from the cwd.
    static func prepare(root: String, disabledServers: [String] = [],
                        host: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexLaunchSetup {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let safeName = { (name: String) in
            (1...64).contains(name.count) && name.unicodeScalars.allSatisfy(allowed.contains)
        }
        guard disabledServers.allSatisfy(safeName) else { throw CodexLaunchSetupError.invalidServerName }
        guard root.hasPrefix("/"), !root.contains("\0"), let real = realpath(root, nil) else {
            throw CodexLaunchSetupError.invalidRoot
        }
        let resolved = String(cString: real); free(real)
        try checkPrivateFolder(resolved)
        let workspace = resolved + "/workspace"
        if mkdir(workspace, 0o700) != 0, errno != EEXIST { throw CodexLaunchSetupError.invalidRoot }
        try checkPrivateFolder(workspace)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: workspace) else {
            throw CodexLaunchSetupError.invalidRoot
        }
        guard entries.isEmpty else { throw CodexLaunchSetupError.workspaceNotEmpty }
        let environment = inheritedVariables.compactMap { name in
            host[name].flatMap { $0.contains("\0") ? nil : "\(name)=\($0)" }
        }
        let overrides = disabledServers.flatMap { ["-c", "mcp_servers.\($0).enabled=false"] }
        return CodexLaunchSetup(workspace: workspace, environment: environment, configOverrides: overrides)
    }

    /// A real directory (not a symlink) owned by this user with no group or other access.
    private static func checkPrivateFolder(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CodexLaunchSetupError.invalidRoot
        }
        guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw CodexLaunchSetupError.unsafeOwnership
        }
    }
}
#endif
