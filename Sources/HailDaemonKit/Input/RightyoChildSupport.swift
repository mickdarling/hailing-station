#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// Why the RightyO child refused to start or its output ended (#203). Cases name rules, never content:
/// `unsafeExecutable`/`unsafeConfig` (see `validate`), `lineTooLong` (a stdout line past `maxLineBytes`),
/// `backlog` (untaken lines past `maxQueuedBytes`), `transportLost`.
public enum RightyoChildError: Error, Sendable, Equatable {
    case unsafeExecutable, unsafeConfig, lineTooLong, backlog, transportLost
}

/// How a reaped child ended.
public enum RightyoChildExit: Sendable, Equatable { case exited(Int32), signaled(Int32) }

extension RightyoChildProcess {
    public struct Timing: Sendable {
        /// After stdin closes, how long the child has to emit `stopped` and exit before SIGTERM.
        public var eofGrace: TimeInterval
        /// After SIGTERM, how long before SIGKILL.
        public var termGrace: TimeInterval
        /// Pending stdin audio is bounded by bytes and age; the oldest whole chunks are dropped first.
        public var backlogBytes: Int
        public var backlogAge: TimeInterval
        public init(eofGrace: TimeInterval = 3, termGrace: TimeInterval = 2, backlogBytes: Int = 65_536,
                    backlogAge: TimeInterval = 2) {
            (self.eofGrace, self.termGrace) = (eofGrace, termGrace)
            (self.backlogBytes, self.backlogAge) = (backlogBytes, backlogAge)
        }
    }
    public struct Counters: Sendable, Equatable {
        public var writtenBytes = 0, droppedChunks = 0, droppedBytes = 0, stderrBytes = 0
    }
    /// RightyO requires `--provenance` with `--mode stdin`; the phone microphone is `live-microphone`.
    public static func arguments(session: String, config: URL,
                                 provenance: RightyoAudioProvenance = .liveMicrophone) -> [String] {
        ["listen", "--mode", "stdin", "--provenance", provenance.rawValue, "--session-id", session,
         "--config", config.path]
    }

    /// PATH is fixed; only HOME and TMPDIR are carried over from the daemon's environment.
    static func environment(_ ambient: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "TMPDIR"] { environment[key] = ambient[key] }
        return environment
    }

    /// The executable (after symlinks) must be a regular executable file owned by this user or root and not
    /// group/world-writable, and so must every directory from its parent up to `/`, so no other user can replace
    /// it between this check and the spawn. Returns the resolved absolute path, which is the one spawned.
    @discardableResult public static func validate(executable: URL, config: URL) throws -> String {
        var info = stat(), parent = stat()
        let resolved = executable.path.hasPrefix("/") ? realpath(executable.path, nil) : nil
        defer { free(resolved) }
        let path = resolved.map { String(cString: $0) } ?? ""
        let owners: Set<uid_t> = [0, getuid()]
        guard executable.isFileURL, !path.isEmpty, stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0, owners.contains(info.st_uid), access(path, X_OK) == 0
        else { throw RightyoChildError.unsafeExecutable }
        var directory = (path as NSString).deletingLastPathComponent
        while true {
            guard stat(directory, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR, owners.contains(parent.st_uid),
                  parent.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw RightyoChildError.unsafeExecutable }
            if directory == "/" { break }
            directory = (directory as NSString).deletingLastPathComponent
        }
        guard config.isFileURL, config.path.hasPrefix("/"), stat(config.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, access(config.path, R_OK) == 0 else {
            throw RightyoChildError.unsafeConfig
        }
        return path
    }

    /// `posix_spawn` of the exact path, never a shell: only the three stdio pipes cross (CLOEXEC_DEFAULT), every
    /// catchable signal is reset to default and none is blocked (the daemon itself ignores SIGTERM), and the
    /// working directory is set by the spawn. The returned stdin end is non-blocking with SIGPIPE suppressed.
    static func spawn(_ executable: String, arguments: [String], environment: [String], directory: String)
        throws -> SpawnedChild {
        var input = [Int32](repeating: -1, count: 2), output = input, errors = input
        var launched = false
        defer { if !launched { (input + output + errors).filter { $0 >= 0 }.forEach { close($0) } } }
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0,
              (input + output + errors).allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }),
              fcntl(input[1], F_SETNOSIGPIPE, 1) == 0, fcntl(input[1], F_SETFL, O_NONBLOCK) == 0,
              !([executable, directory] + arguments + environment).contains(where: { $0.contains("\0") }) else {
            throw RightyoChildError.transportLost
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw RightyoChildError.transportLost }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw RightyoChildError.transportLost }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), unblocked = sigset_t()
        sigemptyset(&defaults); sigemptyset(&unblocked)
        for value in 1..<NSIG where value != SIGKILL && value != SIGSTOP { sigaddset(&defaults, value) }
        let setup = [posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO),
                     posix_spawn_file_actions_addchdir_np(&actions, directory),
                     posix_spawnattr_setsigdefault(&attributes, &defaults),
                     posix_spawnattr_setsigmask(&attributes, &unblocked),
                     posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                                                  | POSIX_SPAWN_SETSIGMASK))]
        guard setup.allSatisfy({ $0 == 0 }) else { throw RightyoChildError.transportLost }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        guard !(argv.dropLast() + envp.dropLast()).contains(nil) else { throw RightyoChildError.transportLost }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp) == 0 else {
            throw RightyoChildError.transportLost
        }
        [input[0], output[1], errors[1]].forEach { close($0) }
        launched = true
        return SpawnedChild(pid: pid, input: input[1], output: output[0], errors: errors[0])
    }

    /// Runs on the reaper queue only. Blocking after the exit event (the child is a zombie by then).
    static func reap(_ pid: pid_t, into exit: RightyoExitLatch, blocking: Bool) -> Bool {
        guard exit.value == nil else { return true }
        var status: Int32 = 0
        var result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
        while result == -1, errno == EINTR { result = waitpid(pid, &status, blocking ? 0 : WNOHANG) }
        guard result == pid else { return false }
        exit.signal(status & 0x7f == 0 ? .exited((status >> 8) & 0xff) : .signaled(status & 0x7f))
        return true
    }

    struct SpawnedChild { let pid: pid_t, input: Int32, output: Int32, errors: Int32 }

    /// Counts stderr bytes and discards them; diagnostics may quote audio-derived text.
    static func drainErrors(_ errors: Int32, counting: (Int) -> Void) {
        defer { close(errors) }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(errors, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            counting(count)
        }
    }
}

/// Pending stdin chunks, FIFO with a head index: append, eviction and expiry are O(1) amortised, even at the
/// gate's 2-byte minimum (32,768 chunks in 64 KB). A taken slot is released at once, so only live chunks hold
/// audio; the dead prefix is compacted once it reaches the live count, and storage resets when empty.
struct RightyoChunkQueue {
    typealias Chunk = (data: Data, at: UInt64)
    private var items: [Chunk?] = [], head = 0
    var isEmpty: Bool { head == items.count }
    var first: Chunk? { isEmpty ? nil : items[head] }
    /// Audio bytes the storage still references (tests; O(n)).
    var storedBytes: Int { items.reduce(0) { $0 + ($1?.data.count ?? 0) } }
    mutating func append(_ item: Chunk) { items.append(item) }
    mutating func removeFirst() -> Chunk {
        guard let chunk = items[head] else { preconditionFailure("RightyoChunkQueue slot already taken") }
        (items[head], head) = (nil, head + 1)
        if isEmpty { items.removeAll(keepingCapacity: true); head = 0 } else if head >= items.count - head {
            items.removeFirst(head); head = 0
        }
        return chunk
    }
}

/// The reaped child's exit, with timed waits.
final class RightyoExitLatch: Sendable {
    private struct Waiting {
        var exit: RightyoChildExit?
        var waiters: [UUID: CheckedContinuation<RightyoChildExit?, Never>] = [:]
    }
    private let state = Mutex(Waiting())
    var value: RightyoChildExit? { state.withLock { $0.exit } }

    func signal(_ exit: RightyoChildExit) {
        let waiters = state.withLock { state in
            state.exit = exit
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume(returning: exit) }
    }

    /// The exit, or nil when `timeout` (seconds) passes first; a nil timeout waits for the exit.
    func wait(timeout: TimeInterval?) async -> RightyoChildExit? {
        let id = UUID()
        return await withCheckedContinuation { waiter in
            let done = state.withLock { state -> RightyoChildExit? in
                if let exit = state.exit { return exit }
                state.waiters[id] = waiter
                return nil
            }
            if let done { return waiter.resume(returning: done) }
            guard let timeout else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: nil)
            }
        }
    }
}
#endif
