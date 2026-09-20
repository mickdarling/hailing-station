public import Foundation

public enum AuditHistoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case noHistory(String)

    public var description: String {
        switch self {
        case .noHistory(let path): "no audit history at \(path)"
        }
    }
}

/// A read-only, chronological view of the audit directory. Each day is capped and verified before the
/// next one is opened, so a complete history may take time but never holds aggregate file contents.
public struct AuditHistory: Sendable {
    public struct Report: Equatable, Sendable {
        public var days: Int
        public var records: Int
        public var lastDay: String?
        public var lastHash: String?
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The audit directory alongside the standard policy file, including `HAIL_CONFIG_DIR` overrides.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        Self(directory: PolicyFile.standard(environment: environment).directory
            .appendingPathComponent("audit", isDirectory: true))
    }

    /// Verifies every real day oldest-to-newest, including its link to the previous real day. Pair-absent
    /// v1 files are accepted only as an initial legacy prefix; they cannot reset an already linked history.
    public func verify() throws -> Report {
        try scan().report
    }

    /// The ten most recent canonical records, across day boundaries, after verifying the whole history.
    public func tail(limit: Int = 10) throws -> [String] {
        try scan(tailLimit: max(0, limit)).tail
    }

    /// Every canonical record for the UTC day containing `date`, after verifying the whole history.
    public func today(at date: Date = Date()) throws -> [String] {
        try scan(collecting: AuditChain.day(of: date)).collected
    }
}

extension AuditHistory {
    struct Scan {
        var report: Report
        var tail: [String]
        var collected: [String]
    }

    /// `retry` is injectable so the torn-read recovery can be deterministic in tests. The production
    /// delay gives the daemon's single append and sync a chance to finish without ever waiting on its lock.
    func scan(
        collecting selectedDay: String? = nil,
        tailLimit: Int = 0,
        retry: () -> Void = { usleep(20_000) },
        afterRead: (Int) -> Void = { _ in }
    ) throws -> Scan {
        let rules = PolicyFile(directory: directory)
        guard let descriptor = try rules.openDirectory() else {
            throw AuditHistoryError.noHistory(directory.path)
        }
        defer { close(descriptor) }
        let days = try dayNames(in: descriptor)
        guard !days.isEmpty else { throw AuditHistoryError.noHistory(directory.path) }
        var previous: AuditLog.PreviousDay?
        var linked = false
        var records = 0
        var recent: [String] = []
        var collected: [String] = []
        for day in days {
            let result = try read(day: day, in: descriptor, retry: retry, afterRead: afterRead)
            let first = try JSONDecoder().decode(AuditRecord.self, from: Data(result.lines[0].utf8))
            linked = try validateLink(first, day: day, previous: previous, afterLinked: linked)
            previous = AuditLog.PreviousDay(day: day, hash: result.tail.lastHash)
            records += result.lines.count
            if day == selectedDay { collected = result.lines }
            if tailLimit > 0 {
                recent.append(contentsOf: result.lines.suffix(tailLimit))
                if recent.count > tailLimit { recent.removeFirst(recent.count - tailLimit) }
            }
        }
        // A real day added or removed while this command walked the directory is not a coherent snapshot.
        guard try dayNames(in: descriptor) == days else {
            throw AuditLogError.inUse(directory.path)
        }
        return Scan(
            report: Report(days: days.count, records: records,
                           lastDay: previous?.day, lastHash: previous?.hash),
            tail: recent, collected: collected
        )
    }

    private func dayNames(in descriptor: Int32) throws -> [String] {
        var days: [String] = []
        for name in try AuditLog.directoryNames(in: descriptor, at: directory) {
            if name.hasPrefix(".") || !name.hasSuffix(".jsonl") { continue }
            guard name.count == 16 else { throw invalidName(name) }
            let day = String(name.dropLast(6))
            guard AuditChain.dayHasShape(day) else { throw invalidName(name) }
            days.append(day)
        }
        return days.sorted()
    }

    private func read(
        day: String, in directoryDescriptor: Int32, retry: () -> Void, afterRead: (Int) -> Void
    ) throws
        -> (lines: [String], tail: AuditChain.Tail) {
        let url = directory.appendingPathComponent("\(day).jsonl")
        for attempt in 0...1 {
            let descriptor = openat(directoryDescriptor, url.lastPathComponent,
                                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT, attempt == 0 { retry(); continue }
                throw errno == ELOOP ? PolicyFileError.wrongType(url.path) : refused(day, "cannot open")
            }
            defer { close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0 else { throw AuditLogError.unwritable(url.path) }
            do {
                let lines = try AuditLog.read(descriptor, at: url)
                afterRead(attempt)
                var after = stat()
                guard fstat(descriptor, &after) == 0 else { throw AuditLogError.unwritable(url.path) }
                if before.st_size != after.st_size {
                    guard attempt == 0 else { throw AuditLogError.inUse(url.path) }
                    retry()
                    continue
                }
                return (lines, try AuditLog.verify(lines: lines, path: url.path, day: day))
            } catch AuditLogError.fileRefused(_, let reason) where reason == "torn last line" && attempt == 0 {
                retry()
            }
        }
        throw refused(day, "torn last line")
    }

    private func validateLink(
        _ first: AuditRecord, day: String, previous: AuditLog.PreviousDay?, afterLinked: Bool
    ) throws -> Bool {
        let hasDay = first.fields["previous_day"] != nil
        let hasHash = first.fields["previous_hash"] != nil
        if !hasDay, !hasHash {
            guard !afterLinked else { throw refused(day, "legacy day follows linked history") }
            return false
        }
        let expectedDay = previous?.day ?? ""
        let expectedHash = previous?.hash ?? AuditChain.genesis
        guard first.fields["previous_day"] == .string(expectedDay),
              first.fields["previous_hash"] == .string(expectedHash) else {
            throw refused(day, "previous day link does not match")
        }
        return true
    }

    private func refused(_ day: String, _ reason: String) -> AuditLogError {
        .fileRefused(path: directory.appendingPathComponent("\(day).jsonl").path, reason: reason)
    }

    private func invalidName(_ name: String) -> AuditLogError {
        .fileRefused(path: directory.appendingPathComponent(name).path, reason: "invalid audit day filename")
    }
}
