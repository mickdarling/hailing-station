#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// The RightyO child's launch rules, stdout/stderr readers and exit latch (#203), beside RightyoChildProcess.swift.
extension RightyoChildProcess {
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

    public static func validate(executable: URL, config: URL) throws {
        var info = stat()
        guard executable.isFileURL, executable.path.hasPrefix("/"), stat(executable.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              access(executable.path, X_OK) == 0 else { throw RightyoChildError.unsafeExecutable }
        guard config.isFileURL, config.path.hasPrefix("/"), stat(config.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, access(config.path, R_OK) == 0 else {
            throw RightyoChildError.unsafeConfig
        }
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

    /// Splits stdout into lines on its own thread and always reads to EOF, so the child never wedges on a full
    /// pipe; after an error or a gone reader the rest is discarded.
    static func readLines(_ output: Int32, into lines: AsyncThrowingStream<Data, any Error>.Continuation) {
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 16_384), line = Data(), open = true
        func fail(_ error: RightyoChildError) { lines.finish(throwing: error); open = false }
        while true {
            let count = buffer.withUnsafeMutableBytes { read(output, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if open, count < 0 { fail(.transportLost) }
                if open, !line.isEmpty, case .dropped = lines.yield(line) { fail(.backlog) }
                if open { lines.finish() }
                return
            }
            guard open else { continue }
            do { open = try split(buffer[..<count], line: &line, into: lines) } catch { fail(error) }
        }
    }

    /// Appends `bytes` to the pending line and yields each completed non-empty line. False once the reader is gone.
    private static func split(_ bytes: ArraySlice<UInt8>, line: inout Data,
                              into lines: AsyncThrowingStream<Data, any Error>.Continuation) throws(RightyoChildError)
        -> Bool {
        let parts = bytes.split(separator: 10, omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            line.append(contentsOf: part)
            guard line.count <= maxLineBytes else { throw .lineTooLong }
            guard index < parts.count - 1, !line.isEmpty else { continue }
            switch lines.yield(line) {
            case .dropped: throw .backlog
            case .terminated: return false
            default: line = Data()
            }
        }
        return true
    }

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

/// What the piped audio is, as RightyO's required `--provenance` flag names it; stamped on every turn.
public enum RightyoAudioProvenance: String, Sendable {
    case liveMicrophone = "live-microphone", recordedFile = "recorded-file", causalReplay = "causal-replay"
    case synthetic
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
