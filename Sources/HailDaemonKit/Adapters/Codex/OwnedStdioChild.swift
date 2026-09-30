#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// Exact-child ownership only. No shell, ambient environment, credentials or daemon registration.
struct OwnedStdioCommand: Sendable {
    let executable: String
    var arguments: [String] = []
    var environment: [String] = []
}

private struct StdioResources {
    var pid: pid_t?
    var input: Int32
    var output: Int32
    var stopped = false
    var writes = 0
    var reads = 0
    var reaps = 0
}

final class OwnedStdioChild: Sendable {
    let chunks: AsyncThrowingStream<Data, any Error>
    private let resources: Mutex<StdioResources>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let exited = DispatchGroup()
    private let writer = DispatchQueue(label: "hailing.owned-stdio.write")
    private let readable: any DispatchSourceRead
    private let processExit: any DispatchSourceProcess
    private let grace: TimeInterval

    init(command: OwnedStdioCommand, grace: TimeInterval = 0.1) throws {
        guard command.executable.hasPrefix("/"), grace > 0, grace <= 1,
              !([command.executable] + command.arguments + command.environment).contains(where: {
                  $0.contains("\0")
              }) else { throw CodexStdioError.invalidConfiguration }
        let (spawned, pid) = try Self.spawn(command)
        resources = Mutex(spawned)
        self.grace = grace
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(4))
        chunks = pair.stream; continuation = pair.continuation
        readable = DispatchSource.makeReadSource(fileDescriptor: spawned.output,
            queue: DispatchQueue(label: "hailing.owned-stdio.read"))
        processExit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        exited.enter()
        exited.enter()
        readable.setEventHandler { self.readReady() }
        readable.setCancelHandler {
            self.resources.withLock { close(spawned.output); $0.output = -1 }
            self.exited.leave()
        }
        processExit.setEventHandler { self.reap(observedExit: true) }
        processExit.setCancelHandler { self.exited.leave() }
        readable.activate(); processExit.activate()
        reap(observedExit: false) // One registration-race check, never idle polling.
    }

    var isReaped: Bool { resources.withLock { $0.pid == nil } }
    var isStopped: Bool { resources.withLock { $0.stopped } }
    var ioChecks: (reads: Int, reaps: Int) { resources.withLock { ($0.reads, $0.reaps) } }
    func cancel() {
        let first = resources.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.stopped = true
            close(state.input); state.input = -1
            if let pid = state.pid { _ = kill(pid, SIGTERM) }
            exited.enter() // Admission precedes any concurrent join observing an empty group.
            return true
        }
        guard first else { return }
        readable.cancel() // Its cancellation handler owns stdout's sole close after in-flight reads finish.
        continuation.finish(throwing: CodexStdioError.stopped)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            defer { self.exited.leave() }
            self.resources.withLock { if let pid = $0.pid { _ = kill(pid, SIGKILL) } }
        }
    }

    func join() async {
        await withCheckedContinuation { joined in exited.notify(queue: .global()) { joined.resume() } }
    }

    func write(_ data: Data) async throws {
        guard data.count <= 65_537 else { throw CodexStdioError.capacityExceeded }
        try resources.withLock { state in
            guard !state.stopped else { throw CodexStdioError.stopped }
            guard state.writes < 4 else { throw CodexStdioError.capacityExceeded }
            state.writes += 1; exited.enter()
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            writer.async {
                defer { self.resources.withLock { $0.writes -= 1 }; self.exited.leave() }
                do { try self.writeAll(data); done.resume() } catch { done.resume(throwing: error) }
            }
        }
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = resources.withLock { state -> Int in
                guard !state.stopped else { return -2 }
                return data.withUnsafeBytes { raw in
                    Darwin.write(state.input, raw.baseAddress?.advanced(by: offset), data.count - offset)
                }
            }
            if count > 0 { offset += count } else if count == -2 { throw CodexStdioError.stopped } else {
                guard errno == EAGAIN || errno == EINTR else {
                    continuation.finish(throwing: CodexStdioError.transportLost)
                    cancel(); throw CodexStdioError.transportLost
                }
                usleep(1_000)
            }
        }
    }

    private func readReady() {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let (count, reason) = resources.withLock { state -> (Int, Int32) in
                guard !state.stopped else { return (-2, 0) }
                state.reads += 1
                let count = buffer.withUnsafeMutableBytes { Darwin.read(state.output, $0.baseAddress, $0.count) }
                return (count, errno)
            }
            if count > 0 {
                if case .enqueued = continuation.yield(Data(buffer.prefix(count))) { continue }
                continuation.finish(throwing: CodexStdioError.capacityExceeded); cancel(); return
            }
            if count == 0 { continuation.finish(); cancel(); return }
            if count == -2 { return }
            if reason == EAGAIN { return } // The dispatch source wakes only when more bytes/EOF become ready.
            guard reason == EINTR else {
                continuation.finish(throwing: CodexStdioError.transportLost); cancel(); return
            }
        }
    }

    private func reap(observedExit: Bool) {
        let reaped = resources.withLock { state -> Bool in
            guard let pid = state.pid else { return true }
            state.reaps += 1
            var status: Int32 = 0
            // Blocking wait occurs only after the owned exit event, not while an idle child is running.
            var result = waitpid(pid, &status, observedExit ? 0 : WNOHANG)
            while result == -1, errno == EINTR { result = waitpid(pid, &status, observedExit ? 0 : WNOHANG) }
            guard result == pid || (result == -1 && errno == ECHILD) else { return false }
            state.pid = nil
            return true
        }
        if reaped { processExit.cancel() }
    }
}

extension OwnedStdioChild {
    private static func spawn(_ command: OwnedStdioCommand) throws -> (StdioResources, pid_t) {
        var input = [Int32](repeating: -1, count: 2), output = input
        guard pipe(&input) == 0 else { throw CodexStdioError.transportLost }
        guard pipe(&output) == 0 else { input.forEach { close($0) }; throw CodexStdioError.transportLost }
        var keep = false
        defer { if !keep { (input + output).forEach { close($0) } } }
        try configure(input: input[1], output: output[0])
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CodexStdioError.transportLost }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CodexStdioError.transportLost }
        defer { posix_spawnattr_destroy(&attributes) }
        let setup = [posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO),
                     posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
                     posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))]
        guard setup.allSatisfy({ $0 == 0 }) else { throw CodexStdioError.transportLost }
        var arguments = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        var environment = command.environment.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        guard arguments.dropLast().allSatisfy({ $0 != nil }),
              environment.dropLast().allSatisfy({ $0 != nil }) else { throw CodexStdioError.transportLost }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, command.executable, &actions, &attributes, &arguments, &environment)
        guard result == 0 else { throw CodexStdioError.transportLost }
        close(input[0]); close(output[1]); keep = true
        return (StdioResources(pid: pid, input: input[1], output: output[0]), pid)
    }
    private static func configure(input: Int32, output: Int32) throws {
        for descriptor in [input, output] {
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw CodexStdioError.transportLost }
        }
        guard fcntl(input, F_SETNOSIGPIPE, 1) == 0 else { throw CodexStdioError.transportLost }
    }
}
#endif
