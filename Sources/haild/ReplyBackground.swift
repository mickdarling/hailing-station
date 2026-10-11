import Darwin
import Foundation
import HailDaemonKit
import Synchronization

/// A target-only spoken reply streams in a detached `haild` (#430), so `haild reply` returns once the text and the
/// first audio are accepted instead of blocking an agent's foreground command for the whole answer.
///
/// The detached job is the same command in its own session: it owns the renderer, its job group and cleanup, stops
/// at the host's first refusal (stop, mute, take-over, expiry), and is bounded by `wallClockBound`. Its stdin and
/// stdout are `/dev/null` and nothing else is inherited, so it never holds the caller's pipes open. Its stderr is a
/// private pipe the caller relays until the job reports ready; an earlier failure is relayed with its exit status.
enum ReplyBackground {
    static let variable = "HAILD_REPLY_BACKGROUND"
    /// The whole detached job: the 30-minute audio bound plus time to render, start and finish.
    static let wallClockBound: Duration = .seconds(ReplyStreamPacer.maxAudioSeconds + 300)
    private static let readyLine = Data("haild: reply streaming in the background\n".utf8)
    private static let relayLimit = 65_536
    private static let startFailure = ReplyCommandError.invalid("cannot start the background reply")
    private static let readied = Mutex(false)

    static var isDetachedJob: Bool { ProcessInfo.processInfo.environment[variable] == "1" }

    /// Starts the detached job and relays its early outcome; never returns.
    static func detach() throws -> Never {
        guard let executable = Bundle.main.executablePath else { throw ReplyCommandError.invalid("cannot find haild") }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw startFailure }
        let pid = try spawn(executable, stderr: ends[1])
        close(ends[1])
        let output = relay(ends[0])
        close(ends[0])
        if output.count >= readyLine.count, output.suffix(readyLine.count) == readyLine {
            FileHandle.standardError.write(output.prefix(output.count - readyLine.count))
            print("submitted text and first audio; the rest streams in the background (pid \(pid))")
            exit(0)
        }
        FileHandle.standardError.write(output)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let exited = status & 0x7f == 0
        exit(exited ? (status >> 8) & 0xff : 1)
    }

    /// In the detached job, after its first accepted audio frame: tell the caller, then let go of its pipe.
    static func ready() {
        guard isDetachedJob, readied.withLock({ done in defer { done = true }; return !done }) else { return }
        _ = readyLine.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 { dup2(null, STDERR_FILENO); close(null) }
    }

    /// Runs the detached job under its wall-clock bound; cancellation stops the renderer and pacing at once.
    static func bounded(_ job: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await job() }
            group.addTask {
                try await Task.sleep(for: wallClockBound)
                throw ReplyCommandError.invalid("background reply exceeded its time bound")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private static func relay(_ descriptor: Int32) -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return output }
            output.append(contentsOf: buffer[0..<count])
            // Bounded, keeping the tail: the ready line, when it comes, is always last.
            if output.count > relayLimit { output = Data(output.suffix(relayLimit)) }
        }
    }

    private static func spawn(_ executable: String, stderr: Int32) throws -> pid_t {
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let setup = [posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                     posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0),
                     posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO),
                     posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))]
        guard setup.allSatisfy({ $0 == 0 }) else { throw startFailure }
        let arguments = [executable] + CommandLine.arguments.dropFirst()
        var environment = ProcessInfo.processInfo.environment
        environment[variable] = "1"
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, argv, envp) == 0 else {
            throw startFailure
        }
        return pid
    }
}
