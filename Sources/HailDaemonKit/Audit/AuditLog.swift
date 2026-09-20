public import Foundation

public enum AuditLogError: Error, Equatable, Sendable {
    case unwritable(String)
    /// Tampered, torn, empty, shortened, or mislabelled: it stays as evidence and the day is refused
    /// until the operator moves it aside (the writer forgets a chain whose salt changed).
    case fileRefused(path: String, reason: String)
    /// Another process holds the file or the directory lock: one writer per file, reported not waited on.
    case inUse(String)
    /// The clock is before this build could exist; nothing is written with a time that cannot be right.
    case clockBeforeBuild
}

/// The audit files (#42 items 1 and 5): one `YYYY-MM-DD.jsonl` per UTC day in a 0700 directory, each
/// 0600, held append-only through one descriptor opened without following links, `fstat`-checked, and
/// `flock`ed for this writer's life: what was verified is what is appended to. A new day file is written
/// under a temporary name and renamed into place (a `.tmp` left by a kill is harmless and skipped).
/// New days name a locked, verified predecessor tail; later days seal earlier ones; signatures wait for #39.
public actor AuditLog {
    public static let fileExtension = "jsonl"
    public static let maxBytes = 256 << 20  // 30 deliveries a minute is 20 MB a day
    public static let earliestDate = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01T00:00:00Z
    public let directory: URL
    let now: @Sendable () -> Date
    var synchronize: @Sendable (Int32) -> Int32 = { fsync($0) }
    var chain: AuditChain?
    var day = ""
    var descriptor: Int32 = -1
    /// What this writer last wrote on each day, so a clock stepping back still finds the older tail.
    struct Written: Equatable {
        var salt, hash: String
        var count: Int
    }
    var written: [String: Written] = [:]

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }
    deinit { if descriptor >= 0 { close(descriptor) } }

    /// Appends to today's file, rotating on a new UTC day; a failed write drops the chain for a re-verify.
    @discardableResult
    public func record(_ event: AuditEvent) throws -> AuditRecord {
        let date = now()
        guard date >= Self.earliestDate else { throw AuditLogError.clockBeforeBuild }
        let today = AuditChain.day(of: date)
        if chain == nil || today != day { try open(day: today, at: date) }
        guard var chain else { throw AuditLogError.unwritable(directory.path) }
        let record = try chain.append(event, at: date)
        try write(try AuditChain.encodeLine(record) + "\n", to: descriptor)
        self.chain = chain
        written[day] = Written(salt: chain.salt, hash: chain.lastHash, count: Int(clamping: chain.nextSeq))
        return record
    }

    public nonisolated func path(day: String) -> URL { directory.appendingPathComponent("\(day).jsonl") }

    /// Reads a day file through a checked, capped descriptor and verifies it, day binding included.
    public nonisolated static func verify(fileAt url: URL, day: String) throws -> AuditChain.Tail {
        let directory = url.deletingLastPathComponent()
        guard let dir = try PolicyFile(directory: directory).openDirectory() else {
            throw AuditLogError.fileRefused(path: url.path, reason: "no such directory")
        }
        defer { close(dir) }
        let fd = openat(dir, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw AuditLogError.fileRefused(path: url.path, reason: "no such file") }
            throw errno == ELOOP ? PolicyFileError.wrongType(url.path) : AuditLogError.unwritable(url.path)
        }
        defer { close(fd) }
        return try verify(lines: try read(fd, at: url), path: url.path, day: day)
    }

    /// Empty, torn (no final newline), or not UTF-8 is a refused file.
    public nonisolated static func lines(of data: Data, path: String) throws -> [String] {
        func refuse(_ reason: String) -> AuditLogError { .fileRefused(path: path, reason: reason) }
        guard !data.isEmpty else { throw refuse("empty day file") }
        guard data.last == UInt8(ascii: "\n") else { throw refuse("torn last line") }
        guard let text = String(data: data, encoding: .utf8) else { throw refuse("not UTF-8") }
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    static func verify(lines: [String], path: String, day: String) throws -> AuditChain.Tail {
        let tail: AuditChain.Tail
        do { tail = try AuditChain.verify(lines: lines) } catch let error as AuditVerifyError {
            throw AuditLogError.fileRefused(path: path, reason: "\(error)")
        }
        let first = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[0].utf8))
        guard case .string(let named)? = first.fields["day"], named == day else {
            throw AuditLogError.fileRefused(path: path, reason: "chain_opened names another day")
        }
        return tail
    }

    static func read(_ fd: Int32, at url: URL) throws -> [String] {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw AuditLogError.unwritable(url.path) }
        try PolicyFile.check(info, at: url, type: S_IFREG)
        guard info.st_size <= maxBytes else { throw AuditLogError.fileRefused(path: url.path, reason: "over 256 MiB") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw AuditLogError.fileRefused(path: url.path, reason: "over 256 MiB") }
        return try lines(of: data, path: url.path)
    }

    func write(_ line: String, to fd: Int32) throws {
        let bytes = Array(line.utf8)
        guard lseek(fd, 0, SEEK_END) + off_t(bytes.count) <= off_t(Self.maxBytes) else {
            let full = path(day: day).path
            reset()
            throw AuditLogError.fileRefused(path: full, reason: "day file at capacity")
        }
        let count = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count, synchronize(fd) == 0 else {
            let failed = path(day: day).path  // before reset clears the day; this file may be torn
            reset()
            throw AuditLogError.unwritable(failed)
        }
    }

    func reset() {
        if descriptor >= 0 { close(descriptor) }
        (descriptor, chain, day) = (-1, nil, "")
    }
    func setSynchronizeForTesting(_ body: @escaping @Sendable (Int32) -> Int32) { synchronize = body }
}
extension AuditLog {
    /// One descriptor, checked and locked, read through and appended through; any failure closes the writer.
    func open(day: String, at date: Date) throws {
        reset()
        do { try openChecked(day: day, at: date) } catch {
            reset()
            throw error
        }
    }

    private func openChecked(day: String, at date: Date) throws {
        let rules = PolicyFile(directory: directory)
        try rules.createDirectoryIfMissing(synchronize: synchronize)
        guard let dir = try rules.openDirectory() else { throw AuditLogError.unwritable(directory.path) }
        defer { close(dir) }
        var tries = 0
        while flock(dir, LOCK_EX | LOCK_NB) != 0 {
            tries += 1
            guard errno == EWOULDBLOCK, tries < 25 else { throw AuditLogError.inUse(directory.path) }
            usleep(20_000)
        }
        defer { flock(dir, LOCK_UN) }
        let name = "\(day).\(Self.fileExtension)"
        let url = path(day: day)
        let previous = try previousDay(before: day, in: dir)
        var info = stat()
        if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw AuditLogError.unwritable(url.path) }
            try create(name: name, day: day, previous: previous, at: date, in: dir)
        }
        guard synchronize(dir) == 0 else { throw AuditLogError.unwritable(directory.path) }
        let fd = openat(dir, name, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ELOOP ? PolicyFileError.wrongType(url.path) : AuditLogError.unwritable(url.path)
        }
        descriptor = fd
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AuditLogError.inUse(url.path) }
        let lines = try Self.read(fd, at: url)
        let tail = try Self.verify(lines: lines, path: url.path, day: day)
        let first = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[0].utf8))
        try checkPrevious(first, against: previous, at: url)
        try checkWritten(against: lines, first: first, day: day, at: url)
        chain = try AuditChain(continuing: tail, first: first)
        self.day = day
    }

    /// The same day and chain (salt) must still hold every record this writer wrote; a replaced chain starts over.
    private func checkWritten(against lines: [String], first: AuditRecord, day: String, at url: URL) throws {
        guard let written = written[day], first.fields["salt"] == .string(written.salt) else { return }
        guard lines.count >= written.count,
              try JSONDecoder().decode(AuditRecord.self, from: Data(lines[written.count - 1].utf8)).hash
                == written.hash else {
            throw AuditLogError.fileRefused(path: url.path, reason: "not what this writer wrote")
        }
    }
    /// `chain_opened` goes to a temporary name, then a rename, so a half-written file never has the real name.
    private func create(name: String, day: String, previous: PreviousDay?, at date: Date, in dir: Int32) throws {
        let line = try AuditChain.encodeLine(try openingRecord(day: day, previous: previous, at: date)) + "\n"
        let temp = ".\(name).\(UUID().uuidString).tmp"
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AuditLogError.unwritable(path(day: day).path) }
        defer { close(fd) }
        do {
            let bytes = Array(line.utf8)
            guard bytes.withUnsafeBufferPointer({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count,
                  fsync(fd) == 0, renameatx_np(dir, temp, dir, name, UInt32(RENAME_EXCL)) == 0 else {
                throw AuditLogError.unwritable(path(day: day).path)
            }
        } catch {
            unlinkat(dir, temp, 0)
            throw error
        }
    }
}
