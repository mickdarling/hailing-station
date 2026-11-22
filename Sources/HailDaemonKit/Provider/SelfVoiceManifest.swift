#if os(macOS)
import Darwin
import Foundation

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
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.limit else { throw SelfVoiceError.manifest }
        return data
    }
}

/// One owner per daemon start and target. The nonblocking directory lock covers suspension and other writers.
actor SelfVoicePublisher {
    private let path: String, renderer: any SelfVoiceRendering
    private let clock: @Sendable () -> Int
    private var cache: [String: (SelfVoiceConfiguration, SelfVoiceManifest.Voice)] = [:]

    init(directory: String, renderer: any SelfVoiceRendering,
         clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }) {
        path = directory
        self.renderer = renderer
        self.clock = clock
    }

    @discardableResult
    func publish(_ configurations: [SelfVoiceConfiguration],
                 beforeManifest: @Sendable () throws -> Void = {}) async throws -> SelfVoiceManifest {
        try SelfVoiceManifest.checkIDs(configurations.map(\.id))
        for voice in configurations { _ = try voice.origin() }
        let directory = try SelfVoiceDirectory(path)
        let old = try directory.previous()
        var timestamp = old.timestamp
        var voices: [SelfVoiceManifest.Voice] = []
        for config in configurations {
            if let (saved, entry) = cache[config.id], saved == config, old.manifest?.voices.contains(entry) == true {
                guard try directory.matches(entry) else { throw SelfVoiceError.manifest }
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
        if manifest != old.manifest {
            try beforeManifest()
            try Task.checkCancellation()
            for entry in voices where try !directory.matches(entry) { throw SelfVoiceError.manifest }
            // Persist WAV directory entries before making their names visible to a child.
            try directory.sync()
            try directory.install(manifest.encoded(), as: SelfVoiceManifest.name, timestamp: max(0, timestamp))
        }
        try directory.sync()
        cache = Dictionary(uniqueKeysWithValues: zip(configurations, voices).map { ($0.0.id, ($0.0, $0.1)) })
        try directory.removeSuperseded(keeping: Set(voices.map(\.file)))
        return manifest
    }
}

final class SelfVoiceDirectory {
    let path: String, descriptor: Int32
    private static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC

    init(_ path: String) throws {
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), !path.contains("\0"), let leaf = parts.last,
              !parts.contains("."), !parts.contains("..") else { throw SelfVoiceError.directory }
        let parent = open("/" + parts.dropLast().joined(separator: "/"), Self.flags)
        guard parent >= 0 else { throw SelfVoiceError.directory }
        defer { close(parent) }
        guard mkdirat(parent, String(leaf), 0o700) == 0 || errno == EEXIST else { throw SelfVoiceError.directory }
        let dir = openat(parent, String(leaf), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw SelfVoiceError.directory }
        self.path = path
        descriptor = dir
        guard flock(dir, LOCK_EX | LOCK_NB) == 0 else { throw SelfVoiceError.directory }
        try checkedNames()
    }

    deinit { close(descriptor) }

    @discardableResult private func checkedNames() throws -> [String] {
        let current = open(path, Self.flags)
        guard current >= 0 else { throw SelfVoiceError.directory }
        defer { close(current) }
        var named = stat(), held = stat()
        guard fstat(current, &named) == 0, fstat(descriptor, &held) == 0,
              named.st_dev == held.st_dev, named.st_ino == held.st_ino else { throw SelfVoiceError.directory }
        try Self.requirePrivate(held, type: S_IFDIR)
        let names = try AuditLog.directoryNames(in: descriptor, at: URL(fileURLWithPath: path))
            .filter { $0 != "." && $0 != ".." }
        for name in names { _ = try info(name) }
        return names
    }

    private func info(_ name: String) throws -> stat {
        var item = stat()
        guard fstatat(descriptor, name, &item, AT_SYMLINK_NOFOLLOW) == 0 else { throw SelfVoiceError.directory }
        try Self.requirePrivate(item, type: S_IFREG)
        return item
    }

    static func requirePrivate(_ info: stat, type: mode_t) throws {
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == type,
              info.st_mode & 0o7777 == (type == S_IFDIR ? 0o700 : 0o600),
              type == S_IFDIR || info.st_nlink == 1 else { throw SelfVoiceError.directory }
    }

    private func read(_ name: String, limit: Int) throws -> (Data, Int)? {
        let file = openat(descriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw SelfVoiceError.directory
        }
        defer { close(file) }
        var item = stat()
        guard fstat(file, &item) == 0 else { throw SelfVoiceError.directory }
        try Self.requirePrivate(item, type: S_IFREG)
        guard item.st_size <= limit else { throw SelfVoiceError.manifest }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == item.st_size else { throw SelfVoiceError.manifest }
        return (data, item.st_mtimespec.tv_sec)
    }

    func previous() throws -> (manifest: SelfVoiceManifest?, timestamp: Int) {
        guard let (data, modified) = try read(SelfVoiceManifest.name, limit: SelfVoiceManifest.limit) else {
            return (nil, -1)
        }
        let old = try JSONDecoder().decode(SelfVoiceManifest.self, from: data)
        _ = try old.encoded()
        return (old, max(modified, old.voices.map(\.renderedAt).max() ?? -1))
    }

    func matches(_ voice: SelfVoiceManifest.Voice) throws -> Bool {
        guard let (data, _) = try read(voice.file, limit: SelfVoiceWave.maxBytes) else { return false }
        return SelfVoiceWave.digest(data) == voice.sha256
    }

    func sync() throws {
        guard fsync(descriptor) == 0 else { throw SelfVoiceError.directory }
    }

    func install(_ data: Data, as name: String, timestamp: Int? = nil) throws {
        try checkedNames()
        let temp = ".self-\(UUID().uuidString).tmp"
        let file = openat(descriptor, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw SelfVoiceError.directory }
        defer { close(file); unlinkat(descriptor, temp, 0) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        if let timestamp {
            // Carry the last enrollment second across restarts, including an empty manifest, without a v1 extension.
            let time = timeval(tv_sec: timestamp, tv_usec: 0)
            guard futimes(file, [time, time]) == 0 else { throw SelfVoiceError.directory }
        }
        try handle.synchronize()
        try checkedNames()
        var opened = stat()
        let named = try info(temp)
        guard fstat(file, &opened) == 0, opened.st_ino == named.st_ino, opened.st_dev == named.st_dev,
              renameatx_np(descriptor, temp, descriptor, name, timestamp == nil ? UInt32(RENAME_EXCL) : 0) == 0
        else { throw SelfVoiceError.directory }
    }

    func removeSuperseded(keeping files: Set<String>) throws {
        for name in try checkedNames() where !files.contains(name) && name.hasPrefix("self-") {
            guard let uuid = UUID(uuidString: String(name.dropFirst(5).dropLast(4))),
                  name == "self-\(uuid.uuidString).wav" else { continue }
            _ = try info(name)
            guard unlinkat(descriptor, name, 0) == 0 else { throw SelfVoiceError.directory }
        }
    }
}
#endif
