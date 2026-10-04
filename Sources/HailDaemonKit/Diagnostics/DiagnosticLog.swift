import CryptoKit
public import Foundation
public import HailProtocol

// The sink, its limits and its file-safety checks stay together so the whole storage contract is one review.
// swiftlint:disable file_length

/// One stored diagnostic (#234): the device's validated event, tagged with the host's receive time, the
/// connection it arrived on and a token for that connection's device. The token is a short hash of the
/// peer's hello name, never the name itself, so nothing the peer chose freely is stored.
public struct DiagnosticRecord: Codable, Sendable, Equatable {
    public var received: Int64
    public var session: UUID
    public var device: String
    public var event: DiagnosticEvent

    public init(received: Int64, session: UUID, device: String, event: DiagnosticEvent) {
        self.received = received
        self.session = session
        self.device = device
        self.event = event
    }
}

/// The opt-in device diagnostics sink (#234), used only when haild runs with `--device-diagnostics`. Events
/// arrive already validated by the strict protocol decoder. Each session and the host as a whole are
/// rate-limited; excess events are dropped and counted, never answered with an error, so diagnostics
/// cannot change a connection's behaviour. Storage is an owner-only (0600) JSONL file in an owner-only
/// directory, rotated once: at most two files of `maxFileBytes` each (5 MiB in all by default).
public actor DiagnosticLog {
    public static let fileName = "diagnostics.jsonl"
    public static let rotatedName = "diagnostics.1.jsonl"
    public static let defaultMaxFileBytes = 5 * 1024 * 1024 / 2

    /// Token buckets in events: a burst of `capacity`, refilled at `perSecond`.
    public struct Rate: Sendable, Equatable {
        public var capacity: Double
        public var perSecond: Double

        public init(capacity: Double, perSecond: Double) {
            self.capacity = capacity
            self.perSecond = perSecond
        }

        public static let session = Rate(capacity: 120, perSecond: 2)
        public static let host = Rate(capacity: 300, perSecond: 5)
    }

    struct Bucket {
        var tokens: Double
        var updated: ContinuousClock.Instant
        var dropped = 0
    }

    public nonisolated let directory: URL
    let maxFileBytes: Int
    let sessionRate: Rate
    let hostRate: Rate
    let now: @Sendable () -> Int64
    let clock: @Sendable () -> ContinuousClock.Instant
    var sessions: [UUID: Bucket] = [:]
    var hostBucket: Bucket?
    public private(set) var writeFailures = 0
    typealias Write = @Sendable (Int32, UnsafeRawPointer?, Int) -> Int
    /// The system `write`; tests substitute one that is interrupted, short or failing.
    var write: Write = { Darwin.write($0, $1, $2) }
    static let maxSessions = 64

    public init(
        directory: URL, maxFileBytes: Int = defaultMaxFileBytes, sessionRate: Rate = .session,
        hostRate: Rate = .host,
        now: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down)) },
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.directory = directory
        self.maxFileBytes = max(1_024, maxFileBytes)
        self.sessionRate = sessionRate
        self.hostRate = hostRate
        self.now = now
        self.clock = clock
    }

    /// The `diagnostics` directory beside the standard policy file, including `HAIL_CONFIG_DIR` overrides.
    public static func standardDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        PolicyFile.standard(environment: environment).directory.appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// Stores what the rate limits admit and returns how many of `events` were stored. Never throws: a
    /// storage failure is counted and the events are dropped.
    @discardableResult
    public func record(_ events: [DiagnosticEvent], session: UUID, device: String) -> Int {
        let at = clock()
        var bucket = sessions[session] ?? Bucket(tokens: sessionRate.capacity, updated: at)
        var host = hostBucket ?? Bucket(tokens: hostRate.capacity, updated: at)
        refill(&bucket, rate: sessionRate, at: at)
        refill(&host, rate: hostRate, at: at)
        let admitted = Int(min(Double(events.count), bucket.tokens.rounded(.down), host.tokens.rounded(.down)))
        bucket.tokens -= Double(admitted)
        host.tokens -= Double(admitted)
        bucket.dropped += events.count - admitted
        let received = now()
        var stored = Array(events.prefix(admitted))
        if admitted > 0, bucket.dropped > 0,
           let dropped = try? DiagnosticEvent(.eventsDropped, timestamp: max(0, received), fields: [
               .count: .integer(Int64(min(bucket.dropped, Int(Int32.max)))), .code: .token("host_rate_limit")
           ]) {
            stored.insert(dropped, at: 0)
            bucket.dropped = 0
        }
        remember(session, bucket)
        hostBucket = host
        guard !stored.isEmpty else { return 0 }
        let name = Self.deviceToken(device)
        do {
            let encoder = FrameCoding.encoder()
            var bytes = Data()
            for event in stored {
                bytes += try encoder.encode(DiagnosticRecord(received: received, session: session, device: name,
                                                             event: event)) + Data([0x0A])
            }
            try append(bytes)
            return admitted
        } catch {
            writeFailures += 1
            return 0
        }
    }

    /// Removes both log files through the same validated directory the writer and readers use: a link, or a
    /// directory open to group or others, is refused. A missing directory has nothing to clear. Safe while the
    /// daemon runs: each append reopens the file.
    public nonisolated static func clear(directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let dir = try openDirectory(directory, create: false)
        defer { close(dir) }
        for name in [fileName, rotatedName] {
            guard unlinkat(dir, name, 0) == 0 || errno == ENOENT else {
                throw DiagnosticLogError.unwritable(directory.appendingPathComponent(name).path)
            }
        }
    }

    /// `dev-` and the first 8 hex digits of the SHA-256 of the hello name: stable per device, never the name.
    public nonisolated static func deviceToken(_ name: String) -> String {
        "dev-" + SHA256.hash(data: Data(name.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func useWrite(_ write: @escaping Write) { self.write = write }

    private func refill(_ bucket: inout Bucket, rate: Rate, at instant: ContinuousClock.Instant) {
        let elapsed = bucket.updated.duration(to: instant)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        bucket.tokens = min(rate.capacity, bucket.tokens + max(0, seconds) * rate.perSecond)
        bucket.updated = instant
    }

    /// Keeps at most `maxSessions` buckets, forgetting the least recently used first.
    private func remember(_ session: UUID, _ bucket: Bucket) {
        sessions[session] = bucket
        guard sessions.count > Self.maxSessions,
              let oldest = sessions.min(by: { $0.value.updated < $1.value.updated })?.key else { return }
        sessions[oldest] = nil
    }
}

public enum DiagnosticLogError: Error, Equatable, Sendable {
    case unwritable(String)
    case unsafe(String)
}

extension DiagnosticLog {
    /// Appends to the current file, rotating first when `bytes` would take it past `maxFileBytes`.
    private func append(_ bytes: Data) throws {
        let dir = try Self.openDirectory(directory, create: true)
        defer { close(dir) }
        var fd = try Self.openFile(Self.fileName, in: dir, at: directory)
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            throw DiagnosticLogError.unwritable(directory.path)
        }
        var length = off_t(info.st_size)
        if Int(length) + bytes.count > maxFileBytes {
            close(fd)
            try Self.requireRegularOrMissing(Self.rotatedName, in: dir, at: directory)
            guard renameat(dir, Self.fileName, dir, Self.rotatedName) == 0 else {
                throw DiagnosticLogError.unwritable(directory.path)
            }
            fd = try Self.openFile(Self.fileName, in: dir, at: directory)
            length = 0
        }
        defer { close(fd) }
        guard Self.writeAll(bytes, to: fd, write: write) else {
            // Never leave half a batch: roll the file back to where this append began.
            _ = ftruncate(fd, length)
            throw DiagnosticLogError.unwritable(directory.path)
        }
    }

    /// Writes every byte, retrying interrupted and short writes; false on any other failure.
    static func writeAll(_ bytes: Data, to fd: Int32, write: Write) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// The rotation target, when present, must be a regular file: rotation never replaces a link or other node.
    private static func requireRegularOrMissing(_ name: String, in dir: Int32, at url: URL) throws {
        var info = stat()
        if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw DiagnosticLogError.unsafe(url.appendingPathComponent(name).path)
            }
        } else if errno != ENOENT {
            throw DiagnosticLogError.unwritable(url.appendingPathComponent(name).path)
        }
    }

    /// The directory, created 0700 when missing, must be a real directory owned by this user and closed to
    /// group and others.
    static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        if create, mkdir(url.path, 0o700) != 0, errno == ENOENT {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = mkdir(url.path, 0o700)
        }
        let dir = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw DiagnosticLogError.unwritable(url.path) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(dir)
            throw DiagnosticLogError.unsafe(url.path)
        }
        return dir
    }

    /// Opens for append without following links, creating 0600; an existing file must be a regular file
    /// owned by this user, and its mode is reset to 0600.
    private static func openFile(_ name: String, in dir: Int32, at url: URL) throws -> Int32 {
        let fd = openat(dir, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        let path = url.appendingPathComponent(name).path
        guard fd >= 0 else { throw DiagnosticLogError.unwritable(path) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw DiagnosticLogError.unsafe(path)
        }
        return fd
    }
}
