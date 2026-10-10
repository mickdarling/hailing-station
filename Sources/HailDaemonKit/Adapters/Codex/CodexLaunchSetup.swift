#if os(macOS)
import Foundation

/// Fixed public-safe refusals: no path or variable value is echoed.
enum CodexLaunchSetupError: Error, Sendable, Equatable {
    case invalidRoot, unsafeOwnership, workspaceNotEmpty, invalidServerName, invalidPath, insideRepository
}

/// How the owned App Server child is started: the owner's normal Codex home and configuration (#153 design
/// revision), an allowlisted slice of the host environment, and an owned empty workspace as the thread's cwd.
struct CodexLaunchSetup: Sendable, Equatable {
    /// Enough for the CLI to find `~/.codex`. Keys, tokens, proxies and anything else in the host environment are
    /// not passed on. haild under launchd has only the system PATH, so the trusted composition supplies the
    /// owner's PATH (for `npx`/`node` MCP servers) explicitly.
    static let inheritedVariables = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "TMPDIR", "SHELL"]

    let workspace: String
    let environment: [String]
    /// Per-launch `-c` overrides that switch off named MCP servers from the owner's config for these sessions only.
    let configOverrides: [String]

    /// `root` and `path` come from trusted host configuration. Creates `root/workspace` (0700) when missing; it
    /// must be a real, private, empty folder outside any git checkout, so no repository instructions are loaded.
    static func prepare(root: String, disabledServers: [String] = [], path: String? = nil,
                        host: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexLaunchSetup {
        guard disabledServers.allSatisfy(isSafeServerName) else { throw CodexLaunchSetupError.invalidServerName }
        if let path, !isSafeSearchPath(path) { throw CodexLaunchSetupError.invalidPath }
        let workspace = try preparedWorkspace(root)
        var inherited = host
        if let path { inherited["PATH"] = path }
        let environment = inheritedVariables.compactMap { name in
            inherited[name].flatMap { $0.contains("\0") ? nil : "\(name)=\($0)" }
        }
        let overrides = disabledServers.flatMap { ["-c", "mcp_servers.\($0).enabled=false"] }
        return CodexLaunchSetup(workspace: workspace, environment: environment, configOverrides: overrides)
    }

    private static func preparedWorkspace(_ root: String) throws -> String {
        guard root.hasPrefix("/"), !root.contains("\0"), let real = realpath(root, nil) else {
            throw CodexLaunchSetupError.invalidRoot
        }
        let resolved = String(cString: real); free(real)
        try checkPrivateFolder(resolved)
        // The same ancestor rule as the binary: nobody else may swap the root or a folder above it.
        guard (try? CodexLauncher.ancestorsAreTrusted((resolved as NSString).deletingLastPathComponent)) == true else {
            throw CodexLaunchSetupError.unsafeOwnership
        }
        var ancestor = resolved
        while true { // Codex reads project instructions from the git root down to the cwd.
            if FileManager.default.fileExists(atPath: ancestor + "/.git") {
                throw CodexLaunchSetupError.insideRepository
            }
            if ancestor == "/" { break }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        let workspace = resolved + "/workspace"
        if mkdir(workspace, 0o700) != 0, errno != EEXIST { throw CodexLaunchSetupError.invalidRoot }
        try checkPrivateFolder(workspace)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: workspace) else {
            throw CodexLaunchSetupError.invalidRoot
        }
        guard entries.isEmpty else { throw CodexLaunchSetupError.workspaceNotEmpty }
        return workspace
    }

    private static func isSafeServerName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return (1...64).contains(name.count) && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Absolute, non-empty components only: a relative or empty component would search the cwd.
    private static func isSafeSearchPath(_ path: String) -> Bool {
        !path.contains("\0") && path.utf8.count <= 4_096
            && path.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { $0.hasPrefix("/") }
    }

    /// A real directory (not a symlink) owned by this user with no group or other mode bits and no extended ACL,
    /// since an ACL can grant another account access the mode bits do not show.
    private static func checkPrivateFolder(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CodexLaunchSetupError.invalidRoot
        }
        guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0, !CodexLauncher.hasExtendedACL(folder: path) else {
            throw CodexLaunchSetupError.unsafeOwnership
        }
    }
}
#endif
