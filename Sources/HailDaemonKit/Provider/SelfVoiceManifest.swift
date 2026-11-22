#if os(macOS)
import Darwin
import Dispatch
import Foundation
import os

struct SelfVoiceManifest: Codable, Equatable {
    struct Voice: Codable, Equatable {
        let id: String, file: String, source: SelfVoiceConfiguration.Source
        let renderedAt: Int, sha256: String
        enum CodingKeys: String, CodingKey { case id, file, source, renderedAt = "rendered_at", sha256 }
    }
    let version: Int, voices: [Voice]
    static let name = "manifest.json"
    static let limit = 16 * 1_024

    static func checkIDs(_ ids: [String]) throws {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".utf8
        guard ids.count <= 16, Set(ids).count == ids.count, ids.allSatisfy({ id in
            (1...64).contains(id.utf8.count) && id.utf8.allSatisfy(alphabet.contains)
        }) else { throw SelfVoiceError.manifest }
    }

    func encoded() throws -> Data {
        try Self.checkIDs(voices.map(\.id))
        guard version == 1, voices.allSatisfy({ voice in
            voice.file.hasSuffix(".wav") && !voice.file.contains("/") && !voice.file.contains("..") &&
                !voice.file.contains("\0") && voice.renderedAt >= 0 && voice.sha256.utf8.count == 64 &&
                voice.sha256.utf8.allSatisfy("0123456789abcdef".utf8.contains)
        }) else { throw SelfVoiceError.manifest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        guard data.count <= Self.limit else { throw SelfVoiceError.manifest }
        return data
    }
}

/// One owner per daemon start and target. The nonblocking directory lock covers suspension and other writers.
actor SelfVoicePublisher {
    private let queue = DispatchSerialQueue(label: "hailing.self-voice.publication", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    let path: String
    private let renderer: (any SelfVoiceRendering)?
    let observeLaunch: SelfVoiceDirectory.Observer?
    let clock: @Sendable () -> Int
    private var cache: [String: (SelfVoiceConfiguration, SelfVoiceManifest.Voice)] = [:]

    init(directory: String, renderer: (any SelfVoiceRendering)? = nil,
         observeLaunch: SelfVoiceDirectory.Observer? = nil,
         clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }) {
        path = directory
        self.renderer = renderer
        self.observeLaunch = observeLaunch
        self.clock = clock
    }

    @discardableResult
    func publish(_ configurations: [SelfVoiceConfiguration],
                 beforeManifest: @Sendable () throws -> Void = {}) async throws -> SelfVoiceManifest {
        guard let renderer else { throw SelfVoiceError.configuration }
        try SelfVoiceManifest.checkIDs(configurations.map(\.id))
        let origins = try configurations.map { try $0.origin() }
        for (voice, origin) in zip(configurations, origins) {
            _ = try await renderer.profileID(named: voice.profile, at: origin)
        }
        return try await withLockedDirectory { publisher, directory in
            try await publisher.publish(configurations, in: directory, using: renderer, beforeManifest: beforeManifest)
        }
    }

    func withLockedDirectory<Value: Sendable>(
        observe: SelfVoiceDirectory.Observer? = nil,
        _ operation: sending (isolated SelfVoicePublisher, SelfVoiceDirectory) async throws -> Value
    ) async throws -> Value {
        let directory = try SelfVoiceDirectory(path, observe: observe)
        let descriptor = directory.descriptor
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SelfVoiceError.directory }
        // A duplicate (including one inherited across fork) can outlive close. Unlock after rollback, before return.
        defer { flock(descriptor, LOCK_UN) }
        try directory.sweepTemporaries()
        do {
            return try await operation(self, directory)
        } catch {
            directory.rollbackAfterFailure()
            throw error
        }
    }

    private func publish(_ configurations: [SelfVoiceConfiguration], in directory: SelfVoiceDirectory,
                         using renderer: any SelfVoiceRendering,
                         beforeManifest: @Sendable () throws -> Void) async throws -> SelfVoiceManifest {
        let old = try directory.previous()
        var timestamp = old.timestamp
        var voices: [SelfVoiceManifest.Voice] = []
        for config in configurations {
            if let (saved, entry) = cache[config.id], saved == config, old.manifest?.voices.contains(entry) == true {
                voices.append(entry)
                continue
            }
            guard timestamp < Int.max else { throw SelfVoiceError.manifest }
            timestamp = max(clock(), timestamp + 1)
            let (entry, wav) = try await renderer.clip(for: config, at: timestamp)
            try directory.install(wav, as: entry.file)
            voices.append(entry)
        }
        let manifest = SelfVoiceManifest(version: 1, voices: voices)
        try beforeManifest()
        try Task.checkCancellation()
        try directory.commit(manifest, timestamp: timestamp)
        cache = Dictionary(uniqueKeysWithValues: zip(configurations, voices).map { ($0.0.id, ($0.0, $0.1)) })
        // A child may have opened the previous manifest and still need to open its WAVs by name.
        let retained = Set((voices + (old.manifest?.voices ?? [])).map(\.file))
        try directory.removeSuperseded(keeping: retained)
        return manifest
    }
}

final class SelfVoiceDirectory {
    let path: String, descriptor: Int32

    private var installedWaves: [String: stat] = [:]

    enum LaunchEvent { case beforeRenameCheck, renameAuthorized, manifestVerified }
    typealias Observer = @Sendable (LaunchEvent) -> Void
    private let observe: Observer?

    fileprivate init(_ path: String, observe: Observer?) throws {
        self.observe = observe
        let parent = try SelfVoicePrivateFile.openParent(path)
        let leaf = parent.leaf
        defer { close(parent.descriptor) }
        guard mkdirat(parent.descriptor, leaf, 0o700) == 0 || errno == EEXIST else { throw SelfVoiceError.directory }
        let dir = openat(parent.descriptor, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw SelfVoiceError.directory }
        self.path = parent.normalizedPath
        descriptor = dir
    }

    fileprivate func sweepTemporaries() throws {
        for name in try checkedNames() where Self.generated(name, prefix: ".self-", suffix: ".tmp") {
            guard unlinkat(descriptor, name, 0) == 0 else { throw SelfVoiceError.directory }
        }
    }

    private static func generated(_ name: String, prefix: String, suffix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuid = name.dropFirst(prefix.count).dropLast(suffix.count)
        return uuid.wholeMatch(of: #/[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}/#) != nil
    }

    @discardableResult private func checkedNames() throws -> [String] {
        try SelfVoicePrivateFile.checkAncestors((path as NSString).deletingLastPathComponent)
        let current = open(path, SelfVoicePrivateFile.flags)
        guard current >= 0 else { throw SelfVoiceError.directory }
        defer { close(current) }
        var named = stat(), held = stat()
        guard fstat(current, &named) == 0, fstat(descriptor, &held) == 0,
              named.st_dev == held.st_dev, named.st_ino == held.st_ino else { throw SelfVoiceError.directory }
        let hasACL = CodexLauncher.hasExtendedACL(descriptor: descriptor)
        try SelfVoicePrivateFile.requirePrivate(held, type: S_IFDIR, hasACL: hasACL)
        let names = try AuditLog.directoryNames(in: descriptor, at: URL(fileURLWithPath: path))
            .filter { $0 != "." && $0 != ".." }
        for name in names { _ = try info(name) }
        return names
    }

    private func info(_ name: String) throws -> stat {
        let file = openat(descriptor, name, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw SelfVoiceError.directory }
        defer { close(file) }
        return try SelfVoicePrivateFile.privateFileInfo(file)
    }

    func previous() throws -> (manifest: SelfVoiceManifest?, timestamp: Int) {
        let previous = try SelfVoicePrivateFile.read(SelfVoiceManifest.name, in: descriptor,
                                                     limit: SelfVoiceManifest.limit)
        guard let (data, modified) = previous else {
            return (nil, -1)
        }
        let old = try JSONDecoder().decode(SelfVoiceManifest.self, from: data)
        _ = try old.encoded()
        // A restore plus clock rollback can repeat a second. RightyO also keys embeddings by the WAV digest.
        return (old, max(modified, old.voices.map(\.renderedAt).max() ?? -1))
    }

    func matches(_ voice: SelfVoiceManifest.Voice) throws -> Bool {
        let wave = try SelfVoicePrivateFile.read(voice.file, in: descriptor, limit: SelfVoiceWave.maxBytes)
        guard let (data, _) = wave else { return false }
        return SelfVoiceWave.digest(data) == voice.sha256
    }

    func sync() throws {
        guard fsync(descriptor) == 0 else { throw SelfVoiceError.directory }
    }

    func install(_ data: Data, as name: String, timestamp: Int? = nil, check: () throws -> Void = {}) throws {
        try check()
        try checkedNames()
        let temp = ".self-\(UUID().uuidString).tmp"
        let file = openat(descriptor, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw SelfVoiceError.directory }
        defer { close(file); unlinkat(descriptor, temp, 0) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        let opened = try SelfVoicePrivateFile.privateFileInfo(file)
        try handle.write(contentsOf: data)
        if let timestamp {
            // Carry the last enrollment second across restarts, including an empty manifest, without a v1 extension.
            let time = timeval(tv_sec: timestamp, tv_usec: 0)
            guard futimes(file, [time, time]) == 0 else { throw SelfVoiceError.directory }
        }
        try handle.synchronize()
        try checkedNames()
        let named = try info(temp)
        guard opened.st_ino == named.st_ino, opened.st_dev == named.st_dev else { throw SelfVoiceError.directory }
        if timestamp == nil {
            try check()
            guard renameatx_np(descriptor, temp, descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
                throw SelfVoiceError.directory
            }
            installedWaves[name] = opened
        } else {
            observe?(.beforeRenameCheck)
            // The deadline lock authorizes the rename and is released before filesystem I/O. A rename
            // authorized before expiry may finish late. All WAVs are installed and synced before this
            // manifest-last rename. The timed-out call returns nil without waiting. The next prepare()
            // rereads enrollment and verifies the on-disk generation before it can return a path.
            // A running child never adopts a late generation: RightyO reads the manifest only at child
            // start (manifest v1, no hot reload), and commit() verifies every WAV digest before this rename.
            try check()
            observe?(.renameAuthorized)
            guard renameatx_np(descriptor, temp, descriptor, name, 0) == 0 else { throw SelfVoiceError.directory }
            installedWaves.removeAll() // The manifest rename committed these names, even if the next sync fails.
        }
    }

    func rollbackWaves() throws {
        var failed = false
        for (name, installed) in installedWaves {
            var named = stat()
            if fstatat(descriptor, name, &named, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno != ENOENT { failed = true }
            } else if named.st_dev == installed.st_dev, named.st_ino == installed.st_ino,
                      unlinkat(descriptor, name, 0) != 0 {
                failed = true
            }
        }
        if failed { throw SelfVoiceError.directory }
    }
}

extension SelfVoiceDirectory {
    func rollbackAfterFailure() {
        do {
            try rollbackWaves()
        } catch {
            Logger(subsystem: "com.mickdarling.hailing-station", category: "self-voice")
                .error("Failed to roll back self-voice WAVs")
        }
    }

    func verifyManifest(_ manifest: SelfVoiceManifest) throws {
        try checkedNames()
        let bytes = try SelfVoicePrivateFile.read(SelfVoiceManifest.name, in: descriptor,
                                                  limit: SelfVoiceManifest.limit)
        guard try bytes?.0 == manifest.encoded() else { throw SelfVoiceError.manifest }
        observe?(.manifestVerified)
    }

    func verifyWaves(_ manifest: SelfVoiceManifest) throws {
        for entry in manifest.voices where try !matches(entry) { throw SelfVoiceError.manifest }
    }

    func commit(_ manifest: SelfVoiceManifest, timestamp: Int, check: () throws -> Void = {}) throws {
        try check()
        try verifyWaves(manifest)
        try check()
        try sync()
        try install(manifest.encoded(), as: SelfVoiceManifest.name, timestamp: max(0, timestamp), check: check)
        try sync()
    }

    func removeSuperseded(keeping files: Set<String>) throws {
        let names = try checkedNames()
        let retained = try files.compactMap { name -> stat? in
            var item = stat()
            if fstatat(descriptor, name, &item, AT_SYMLINK_NOFOLLOW) == 0 { return item }
            if errno == ENOENT || errno == ENAMETOOLONG { return nil }
            throw SelfVoiceError.directory
        }
        for name in names where Self.generated(name, prefix: "self-", suffix: ".wav") {
            let candidate = try info(name)
            if retained.contains(where: { $0.st_dev == candidate.st_dev && $0.st_ino == candidate.st_ino }) { continue }
            guard unlinkat(descriptor, name, 0) == 0 else { throw SelfVoiceError.directory }
        }
    }
}

// Slice 1's predicate entry points also serve its existing pure security tests.
extension SelfVoiceDirectory {
    static func requirePrivate(_ info: stat, type: mode_t, hasACL: Bool) throws {
        try SelfVoicePrivateFile.requirePrivate(info, type: type, hasACL: hasACL)
    }

    static func requireAncestor(_ info: stat, writableACL: Bool) throws {
        try SelfVoicePrivateFile.requireAncestor(info, writableACL: writableACL)
    }
}

enum SelfVoicePrivateFile {
    static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC

    struct Parent {
        let descriptor: Int32
        let leaf: String, normalizedPath: String
    }

    static func openParent(_ path: String) throws -> Parent {
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), !path.contains("\0"), let leaf = parts.last,
              !parts.contains("."), !parts.contains("..") else { throw SelfVoiceError.directory }
        let parentPath = "/" + parts.dropLast().joined(separator: "/")
        try checkAncestors(parentPath)
        let parent = open(parentPath, flags)
        guard parent >= 0 else { throw SelfVoiceError.directory }
        return Parent(descriptor: parent, leaf: String(leaf), normalizedPath: "/" + parts.joined(separator: "/"))
    }

    static func privateFileInfo(_ file: Int32) throws -> stat {
        var item = stat()
        guard fstat(file, &item) == 0 else { throw SelfVoiceError.directory }
        try Self.requirePrivate(item, type: S_IFREG, hasACL: CodexLauncher.hasExtendedACL(descriptor: file))
        return item
    }

    static func requirePrivate(_ info: stat, type: mode_t, hasACL: Bool) throws {
        guard !hasACL, info.st_uid == getuid(), info.st_mode & S_IFMT == type,
              info.st_mode & 0o7777 == (type == S_IFDIR ? 0o700 : 0o600),
              type == S_IFDIR || info.st_nlink == 1 else { throw SelfVoiceError.directory }
    }

    static func read(_ name: String, in descriptor: Int32, limit: Int) throws -> (Data, Int)? {
        let file = openat(descriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw SelfVoiceError.directory
        }
        defer { close(file) }
        let item = try privateFileInfo(file)
        guard item.st_size <= limit else { throw SelfVoiceError.manifest }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == item.st_size else { throw SelfVoiceError.manifest }
        return (data, item.st_mtimespec.tv_sec)
    }

    static func checkAncestors(_ parent: String) throws {
        var path = parent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var ancestors = [path]
        while path != home && path != "/" {
            path = (path as NSString).deletingLastPathComponent
            ancestors.append(path)
        }
        for ancestor in ancestors.reversed() {
            var info = stat()
            guard lstat(ancestor, &info) == 0 else { throw SelfVoiceError.directory }
            try requireAncestor(info, writableACL: CodexLauncher.aclAllowsChanges(folder: ancestor))
        }
    }

    static func requireAncestor(_ info: stat, writableACL: Bool) throws {
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() || info.st_uid == 0,
              info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0,
              !writableACL else { throw SelfVoiceError.directory }
    }
}
// Keep the locked file transaction in this slice's two production files.
// swiftlint:disable:next file_length
#endif
