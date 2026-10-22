#if os(macOS)
import Darwin
public import Foundation

/// Privacy mode's state across a restart (#735 S-2b, internally duck): one content-free file, `privacy/state.json` in
/// haild's own config directory (`~/.config/hail`, or `HAIL_CONFIG_DIR`), never the shared temp folder. It holds
/// `{"private":true,"since":<unix seconds>}` and nothing else: no words, no names, no ids.
/// - Entering privacy writes it before the entry is confirmed (before the clip and the device notice): a temp file in
///   the same directory, mode 0600, fsynced, renamed over the file, then the directory fsynced. The directory is 0700.
/// - It is removed only after the host confirmed an exit to the device; never on a disconnect, a shutdown or a crash.
/// - At startup, only a missing file reads `public`. A private record, or anything else (corrupt, unreadable, not a
///   regular file), reads private: fail closed. Reading it never ends privacy.
public struct AmbientPrivacyState: Sendable, Equatable {
    /// What the file said at startup; every case but `public` starts haild private.
    public enum Reading: String, Sendable { case `public`, `private`, corrupt, unreadable }

    public let directory: URL
    public var file: URL { directory.appendingPathComponent("state.json") }
    /// A record is a few dozen bytes; anything larger is corrupt.
    static let maxBytes = 256

    public init(directory: URL) { self.directory = directory }

    /// `privacy/` beside the standard policy file, including `HAIL_CONFIG_DIR` overrides.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> AmbientPrivacyState {
        AmbientPrivacyState(directory: PolicyFile.standard(environment: environment).directory
            .appendingPathComponent("privacy", isDirectory: true))
    }

    /// The record, exactly: `{"private":true,"since":<seconds>}` and a newline.
    static func record(since: Date) -> Data {
        Data("{\"private\":true,\"since\":\(Int64(since.timeIntervalSince1970.rounded(.down)))}\n".utf8)
    }

    public func read() -> Reading {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .public : .unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .unreadable }
        var buffer = [UInt8](repeating: 0, count: Self.maxBytes + 1)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count >= 0 else { return .unreadable }
        guard count <= Self.maxBytes, Self.isRecord(Data(buffer[..<count])) else { return .corrupt }
        return .private
    }

    /// Exactly two keys: `private`, the boolean true, and `since`, a non-negative integer.
    static func isRecord(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object.count == 2,
              let flag = object["private"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue,
              let since = object["since"] as? NSNumber, CFGetTypeID(since) != CFBooleanGetTypeID(),
              since.int64Value >= 0, since.doubleValue == Double(since.int64Value) else { return false }
        return true
    }

    /// Writes the record atomically (temp file in the same directory, 0600, fsync, rename, directory fsync).
    func enter(since: Date = Date()) throws {
        try prepareDirectory()
        let temporary = directory.appendingPathComponent(".state-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AmbientPrivacyStateError.writeFailed }
        let bytes = Self.record(since: since)
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        let synced = fchmod(descriptor, 0o600) == 0 && written == bytes.count && fsync(descriptor) == 0
        close(descriptor)
        guard synced, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            throw AmbientPrivacyStateError.writeFailed
        }
        try syncDirectory()
    }

    /// Removes the record; already gone is fine.
    func clear() throws {
        guard unlink(file.path) == 0 || errno == ENOENT else { throw AmbientPrivacyStateError.clearFailed }
        try? syncDirectory()
    }

    /// The directory, created 0700 when missing; it must be a real directory owned by this user, closed to others.
    private func prepareDirectory() throws {
        try? FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw AmbientPrivacyStateError.writeFailed }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & (S_IRWXG | S_IRWXO) == 0 else { throw AmbientPrivacyStateError.unsafeDirectory }
    }

    private func syncDirectory() throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AmbientPrivacyStateError.writeFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw AmbientPrivacyStateError.writeFailed }
    }
}

/// Why the privacy state file could not be written or removed. Rule names only.
public enum AmbientPrivacyStateError: Error, Sendable, Equatable {
    case writeFailed, clearFailed, unsafeDirectory
}
#endif
