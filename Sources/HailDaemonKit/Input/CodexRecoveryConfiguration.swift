#if os(macOS)
import Darwin
import Foundation

enum CodexRecoveryFault: Error, Sendable, Equatable { case unavailable, stopped, timeout, busy }

/// Explicit owner-private manifest; no path or runtime choice comes from a transcript or peer frame.
struct CodexRecoveryConfiguration: Sendable {
    let target: String, binding: String
    let command: OwnedStdioCommand
    static func load(_ file: URL) throws -> Self {
        do { return try checked(file) } catch { throw CodexRecoveryFault.unavailable }
    }
    private static func checked(_ file: URL) throws -> Self {
        let manifest = try privateObject(file)
        guard Set(manifest.keys) == ["version", "profile", "runner", "python", "node"],
              (manifest["version"] as? NSNumber)?.objCType.pointee != 99,
              manifest["version"] as? Int == 1,
              let profile = manifest["profile"] as? String, let runner = manifest["runner"] as? String,
              let python = manifest["python"] as? String, let node = manifest["node"] as? String else {
            throw CodexRecoveryFault.unavailable
        }
        let settings = try privateObject(URL(fileURLWithPath: profile))
        guard settings["version"] as? Int == 1, let target = settings["target"] as? String,
              let binding = settings["binding"] as? String, target.hasPrefix("tmux:"), !binding.isEmpty else {
            throw CodexRecoveryFault.unavailable
        }
        let program = try resource(python, executable: true)
        let script = try resource(runner, executable: false)
        let runtime = try resource(node, executable: true)
        try delegatedCode(beside: script)
        return Self(target: target, binding: binding, command: OwnedStdioCommand(
            executable: program, arguments: ["-I", script, "host", "--config", profile, "--node", runtime],
            environment: ["PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"]))
    }
    /// Reuse the existing Codex path-trust checks, without enabling the experimental provider adapter.
    private static func resource(_ raw: String, executable: Bool) throws -> String {
        guard raw.hasPrefix("/"), !raw.contains("\0"), let pointer = realpath(raw, nil) else {
            throw CodexRecoveryFault.unavailable
        }
        defer { free(pointer) }
        let path = String(cString: pointer), descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CodexRecoveryFault.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              CodexLauncher.safelyOwned(info), !CodexLauncher.hasExtendedACL(descriptor: descriptor),
              try CodexLauncher.ancestorsAreTrusted((path as NSString).deletingLastPathComponent),
              !executable || access(path, X_OK) == 0 else { throw CodexRecoveryFault.unavailable }
        return path
    }
    private static func delegatedCode(beside runner: String) throws {
        let directory = URL(fileURLWithPath: runner).deletingLastPathComponent()
        for name in ["host.cjs", "index.cjs", "node_modules/ws/package.json"] {
            _ = try resource(directory.appendingPathComponent(name).path, executable: false)
        }
        let dependency = directory.appendingPathComponent("node_modules/ws")
        guard let files = FileManager.default.enumerator(at: dependency,
            includingPropertiesForKeys: nil, options: []) else { throw CodexRecoveryFault.unavailable }
        var count = 0
        while let file = files.nextObject() as? URL {
            count += 1
            var info = stat()
            guard count <= 256, lstat(file.path, &info) == 0,
                  CodexLauncher.safelyOwned(info), !CodexLauncher.hasExtendedACL(folder: file.path) else {
                throw CodexRecoveryFault.unavailable
            }
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            guard info.st_mode & S_IFMT == S_IFREG else { throw CodexRecoveryFault.unavailable }
        }
    }
    private static func privateObject(_ file: URL) throws -> [String: Any] {
        guard file.isFileURL, file.path.hasPrefix("/") else { throw CodexRecoveryFault.unavailable }
        let parent = file.deletingLastPathComponent().path
        guard try CodexLauncher.ancestorsAreTrusted(parent) else { throw CodexRecoveryFault.unavailable }
        let directory = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw CodexRecoveryFault.unavailable }
        defer { close(directory) }
        var folder = stat()
        guard fstat(directory, &folder) == 0, folder.st_uid == getuid(), folder.st_mode & 0o077 == 0,
              !CodexLauncher.hasExtendedACL(descriptor: directory) else { throw CodexRecoveryFault.unavailable }
        let descriptor = openat(directory, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CodexRecoveryFault.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var before = stat(), after = stat(), named = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_mode & 0o077 == 0, before.st_nlink == 1,
              before.st_size <= 8192, !CodexLauncher.hasExtendedACL(descriptor: descriptor),
              let data = try handle.read(upToCount: 8193), data.count <= 8192,
              fstat(descriptor, &after) == 0,
              fstatat(directory, file.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexRecoveryFault.unavailable
        }
        return object
    }
}
#endif
