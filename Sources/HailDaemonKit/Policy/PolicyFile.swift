public import Foundation

/// Where the policy lives between runs (#41 item 1). `HailHost` loads it once and saves after every
/// change; both calls are synchronous so a change is committed under the host's isolation with no
/// suspension in which a second change could read stale state.
public protocol PolicyStore: Sendable {
    /// The stored policy, or the empty deny-all policy when nothing has been stored yet. Throws when
    /// something is stored and cannot be trusted: unreadable, malformed, wrong owner or permissions.
    func load() throws -> Policy
    /// Loads, applies `change`, and saves as one transaction against the store, so two writers (two CLI
    /// invocations, a CLI and the daemon) cannot undo each other's changes. Returns what is now stored;
    /// nothing is written when `change` throws or changes nothing.
    func update(_ change: (inout Policy) throws -> Void) throws -> PolicyUpdate
    /// One line for `haild status`: where the policy is and whether it is signed.
    var summary: String { get }
}

/// Optional change tracking for stores that can observe a separate writer without reading policy content.
protocol PolicyChangeTracking: PolicyStore {
    func observation() throws -> PolicyObservation
    /// Metadata comes from the descriptors used for this read, never a separate path lookup.
    func loadObserved() throws -> ObservedPolicy
    /// Monotonic time, injectable so replacement-race tests can exclude process coordination waits.
    var reloadNow: ContinuousClock.Instant { get }
}

struct PolicyDirectoryIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
}

struct PolicyObservation: Equatable, Sendable {
    /// Nil always accompanies the empty policy in an observed read.
    let identity: PolicyFileIdentity?
    var directory: PolicyDirectoryIdentity?
}

struct ObservedPolicy: Sendable {
    let policy: Policy
    let observation: PolicyObservation
    /// Grant differences seen even in discarded attempts of this reload.
    var changedTargets: Set<String> = []
}

extension PolicyChangeTracking {
    var reloadNow: ContinuousClock.Instant { .now }

    func loadStable(
        after before: PolicyObservation? = nil, comparedTo applied: Policy? = nil
    ) throws -> ObservedPolicy {
        let deadline = reloadNow.advanced(by: .milliseconds(50))
        var before = try before ?? observation()
        let directory = before.directory
        let grants = applied?.targets ?? [:]
        var changedTargets: Set<String> = []
        // Stay in this synchronous observation turn, outside the generation lock. No sleeps or stale admission.
        for attempt in 0..<3 {
            guard attempt == 0 || reloadNow < deadline else { break }
            var read = try loadObserved()
            let targets = Set(grants.keys).union(read.policy.targets.keys)
            changedTargets.formUnion(targets.filter { grants[$0] != read.policy.targets[$0] })
            // Always finish checking a started attempt: elapsed time cannot invalidate a stable read.
            let after = try observation()
            // Retain the original directory across retries, including a swap between two observations.
            if let directory,
               read.observation.directory != directory || after.directory != directory { break }
            if read.observation == before, read.observation == after {
                read.changedTargets = changedTargets
                return read
            }
            // The budget gates only retries, including their extra initial observation.
            guard attempt < 2, reloadNow < deadline else { break }
            before = try observation()
        }
        throw HostError.policyUnavailable("policy_changed_during_reload")
    }
}

struct PolicyFileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let modified: Duration
    let size: Int64
}
/// What a policy transaction committed. A rename changes the policy atomically; a later directory-sync
/// failure means the new entry may not survive a crash, but callers must still adopt what readers now see.
public struct PolicyUpdate: Sendable, Equatable {
    public let policy: Policy
    public let durabilityFailure: PolicyFileError?
    public init(policy: Policy, durabilityFailure: PolicyFileError? = nil) {
        self.policy = policy
        self.durabilityFailure = durabilityFailure
    }
}

public enum PolicyFileError: Error, Equatable, Sendable {
    /// The path exists but is not the plain directory or regular file expected (a symlink counts).
    case wrongType(String)
    case wrongOwner(String)
    /// Group or other bits are set; the mode is the low nine bits as octal text.
    case wrongPermissions(path: String, mode: String)
    case malformed(String)
    case unwritable(String)
    /// Another policy writer held the directory lock past the bounded wait.
    case busy(String)
}

/// `~/.config/hail/policy.json`: 0600 in a 0700 directory, both owned by the user, neither a symlink,
/// every open relative to the checked directory descriptor, written whole through a temp file and a
/// rename so a reader never sees half a file. UNSIGNED until the
/// host key exists (#39); the threat model records the residual: any process running as the user can
/// edit it undetected. What this does catch: another user (permissions), a swapped-in symlink, a file
/// that no longer parses, and any key the daemon does not know (`Policy+Codable`).
public struct PolicyFile: PolicyStore, PolicyChangeTracking {
    public static let fileName = "policy.json"
    /// More than this is not a policy this daemon wrote; refused before any decoding work.
    public static let maxBytes = 1 << 20
    static let lockAttempts = 26
    static let lockRetryMicroseconds: useconds_t = 10_000
    public let directory: URL
    public var path: URL { directory.appendingPathComponent(Self.fileName) }
    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/.config/hail`, or `HAIL_CONFIG_DIR` when set (a scratch directory for tests and trials).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> PolicyFile {
        if let dir = environment["HAIL_CONFIG_DIR"], !dir.isEmpty {
            return PolicyFile(directory: URL(fileURLWithPath: dir, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return PolicyFile(directory: home.appendingPathComponent(".config/hail", isDirectory: true))
    }
    public var summary: String { "\(path.path) (unsigned until #39)" }
    public func load() throws -> Policy {
        try load(beforeDecode: {})
    }
    /// Internal read boundary for deterministic replacement-race tests; normal reads install no hook.
    func load(beforeDecode: () -> Void) throws -> Policy {
        try loadObserved(beforeDecode: beforeDecode).policy
    }
    func loadObserved() throws -> ObservedPolicy { try loadObserved(beforeDecode: {}) }
    func loadObserved(beforeDecode: () -> Void) throws -> ObservedPolicy {
        guard let dir = try openDirectory() else {
            return ObservedPolicy(policy: Policy(), observation: PolicyObservation(identity: nil))
        }
        defer { close(dir) }
        return try read(in: dir, beforeDecode: beforeDecode)
    }
    /// Holds an exclusive `flock` on the directory for the whole load, change, write.
    public func update(_ change: (inout Policy) throws -> Void) throws -> PolicyUpdate {
        try update(synchronizeDirectory: { fsync($0) }, change)
    }
    func update(
        synchronizeDirectory: (Int32) -> Int32,
        waitBetweenAttempts: (useconds_t) -> Void = { usleep($0) },
        _ change: (inout Policy) throws -> Void
    ) throws -> PolicyUpdate {
        try createDirectoryIfMissing()
        guard let dir = try openDirectory() else { throw Self.unwritable(directory) }
        defer { close(dir) }
        try lock(dir, waitBetweenAttempts: waitBetweenAttempts)
        defer { flock(dir, LOCK_UN) }
        let before = try load(in: dir)
        var policy = before
        try change(&policy)
        guard policy != before else { return PolicyUpdate(policy: policy) }
        let durabilityFailure = try write(policy, in: dir, synchronizeDirectory: synchronizeDirectory)
        return PolicyUpdate(policy: policy, durabilityFailure: durabilityFailure)
    }
    /// Replaces a missing or malformed regular policy while holding the writer lock. `update` is the normal
    /// mutation path; this unconditional write exists for tests and an eventual explicit repair command.
    public func save(_ policy: Policy) throws {
        _ = try PolicyEvaluator(policy: policy)
        try createDirectoryIfMissing()
        guard let dir = try openDirectory() else { throw Self.unwritable(directory) }
        defer { close(dir) }
        try lock(dir, waitBetweenAttempts: { usleep($0) })
        defer { flock(dir, LOCK_UN) }
        try checkExistingFile(in: dir)
        if let failure = try write(policy, in: dir, synchronizeDirectory: { fsync($0) }) { throw failure }
    }
}

extension PolicyFile {
    func identity() throws -> PolicyFileIdentity? { try observation().identity }

    /// Two lstats, no opens or content reads. Validate the directory even when the file is unchanged.
    func observation() throws -> PolicyObservation {
        let directoryInfo = try Self.info(directory)
        if let directoryInfo { try Self.check(directoryInfo, at: directory, type: S_IFDIR) }
        let info = try Self.info(path)
        if let info { try Self.checkReadable(info, at: path) }
        return PolicyObservation(identity: info.map(Self.identity),
                                 directory: directoryInfo.map { .init(device: $0.st_dev, inode: $0.st_ino) })
    }

    private static func identity(_ info: stat) -> PolicyFileIdentity {
        PolicyFileIdentity(device: info.st_dev, inode: info.st_ino,
                           modified: .seconds(info.st_mtimespec.tv_sec) + .nanoseconds(info.st_mtimespec.tv_nsec),
                           size: info.st_size)
    }

    private static func checkReadable(_ info: stat, at path: URL) throws {
        try check(info, at: path, type: S_IFREG)
        guard info.st_mode & 0o400 != 0 else {
            throw PolicyFileError.wrongPermissions(path: path.path, mode: String(info.st_mode & 0o777, radix: 8))
        }
    }

    private func load(in dir: Int32) throws -> Policy { try read(in: dir).policy }

    private func read(in dir: Int32, beforeDecode: () -> Void = {}) throws -> ObservedPolicy {
        var directoryInfo = stat()
        guard fstat(dir, &directoryInfo) == 0 else { throw PolicyFileError.malformed(directory.path) }
        let location = PolicyObservation(identity: nil,
                                         directory: .init(device: directoryInfo.st_dev, inode: directoryInfo.st_ino))
        // Opened relative to the checked directory, never following a link, never blocking on a FIFO; then
        // the descriptor itself is checked: what is checked is what is read.
        let descriptor = openat(dir, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return ObservedPolicy(policy: Policy(), observation: location) }
            if errno == ELOOP { throw PolicyFileError.wrongType(path.path) }
            throw PolicyFileError.malformed("\(path.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else { throw PolicyFileError.malformed(path.path) }
        try Self.checkReadable(fileInfo, at: path)
        let data: Data
        do {
            data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        } catch {
            throw PolicyFileError.malformed("\(path.path): \(error.localizedDescription)")
        }
        guard data.count <= Self.maxBytes else { throw PolicyFileError.malformed("\(path.path): over 1 MiB") }
        var after = stat()
        guard fstat(descriptor, &after) == 0, Self.identity(after) == Self.identity(fileInfo),
              data.count == fileInfo.st_size else { throw PolicyFileError.malformed(path.path) }
        beforeDecode()
        do {
            let policy = try JSONDecoder().decode(Policy.self, from: data)
            return ObservedPolicy(policy: policy, observation: PolicyObservation(
                identity: Self.identity(fileInfo), directory: location.directory
            ))
        } catch {
            throw PolicyFileError.malformed("\(path.path): \(error)")
        }
    }
    /// Whole file through a temp name and a rename in the locked directory. After rename the new policy
    /// is committed for readers; a directory-sync failure is returned separately because a crash could
    /// still resurrect the old entry.
    private func write(
        _ policy: Policy, in dir: Int32, synchronizeDirectory: (Int32) -> Int32
    ) throws -> PolicyFileError? {
        let tempName = ".\(Self.fileName).\(UUID().uuidString).tmp"
        let descriptor = openat(dir, tempName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.unwritable(directory.appendingPathComponent(tempName)) }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: try Policy.encoder().encode(policy) + Data("\n".utf8))
            try handle.synchronize()
            try handle.close()
            guard renameat(dir, tempName, dir, Self.fileName) == 0 else { throw Self.unwritable(path) }
        } catch {
            unlinkat(dir, tempName, 0)
            throw error
        }
        guard synchronizeDirectory(dir) == 0 else { return Self.unwritable(directory) }
        return nil
    }
    /// Shared with the audit writer (#42), whose directory follows the same rules.
    func createDirectoryIfMissing(
        synchronize: (Int32) -> Int32 = { fsync($0) },
        makeDirectory: (Int32, String, mode_t) -> Int32 = { mkdirat($0, $1, $2) }
    ) throws {
        let parent = directory.deletingLastPathComponent()
        let parentWasMissing = try Self.info(parent) == nil
        if parentWasMissing {
            try PolicyFile(directory: parent).createDirectoryIfMissing(
                synchronize: synchronize, makeDirectory: makeDirectory
            )
        }
        let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.unwritable(parent) }
        defer { close(descriptor) }
        if try Self.info(directory) == nil {
            // A pre-existing parent may be residue from a prior failed parent sync. Repair its entry
            // before putting anything below it, so retry cannot report an undurable subtree as saved.
            if !parentWasMissing, parent.path != "/" {
                let ancestor = open(parent.deletingLastPathComponent().path,
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard ancestor >= 0 else { throw Self.unwritable(parent.deletingLastPathComponent()) }
                defer { close(ancestor) }
                guard synchronize(ancestor) == 0 else { throw Self.unwritable(parent.deletingLastPathComponent()) }
            }
            if makeDirectory(descriptor, directory.lastPathComponent, 0o700) != 0, errno != EEXIST {
                throw Self.unwritable(directory)
            }
            guard let created = try Self.info(directory) else { throw Self.unwritable(directory) }
            try Self.check(created, at: directory, type: S_IFDIR)
        }
        guard synchronize(descriptor) == 0 else { throw Self.unwritable(parent) }
    }
    private func lock(_ descriptor: Int32, waitBetweenAttempts: (useconds_t) -> Void) throws {
        for attempt in 0..<Self.lockAttempts {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw Self.unwritable(directory) }
            if attempt + 1 < Self.lockAttempts { waitBetweenAttempts(Self.lockRetryMicroseconds) }
        }
        throw PolicyFileError.busy(directory.path)
    }

    private func checkExistingFile(in dir: Int32) throws {
        var info = stat()
        guard fstatat(dir, Self.fileName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw PolicyFileError.malformed("\(path.path): \(String(cString: strerror(errno)))")
        }
        try Self.check(info, at: path, type: S_IFREG)
    }

    /// The directory as a descriptor, checked by `fstat`, so every later open is relative to what was
    /// checked. `nil` when it does not exist.
    func openDirectory() throws -> Int32? {
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR { throw PolicyFileError.wrongType(directory.path) }
            throw PolicyFileError.malformed("\(directory.path): \(String(cString: strerror(errno)))")
        }
        var dirInfo = stat()
        guard fstat(dir, &dirInfo) == 0 else {
            close(dir)
            throw PolicyFileError.malformed(directory.path)
        }
        do {
            try Self.check(dirInfo, at: directory, type: S_IFDIR)
        } catch {
            close(dir)
            throw error
        }
        return dir
    }

    private static func unwritable(_ url: URL) -> PolicyFileError {
        .unwritable("\(url.path): \(String(cString: strerror(errno)))")
    }

    /// `lstat`, so a symlink is reported as itself and never followed. `nil` when nothing is there.
    static func info(_ url: URL) throws -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw PolicyFileError.malformed("\(url.path): \(String(cString: strerror(errno)))")
        }
        return info
    }

    /// Shared with the audit writer (#42): the same owner, type, and mode rules for every private file.
    static func check(_ info: stat, at url: URL, type: mode_t) throws {
        guard info.st_mode & S_IFMT == type else { throw PolicyFileError.wrongType(url.path) }
        guard info.st_uid == getuid() else { throw PolicyFileError.wrongOwner(url.path) }
        guard info.st_mode & 0o077 == 0 else {
            throw PolicyFileError.wrongPermissions(path: url.path, mode: String(info.st_mode & 0o777, radix: 8))
        }
    }
    // Persistence stays in one production file to preserve the four-file PR cap.
    // swiftlint:disable:next file_length
}
