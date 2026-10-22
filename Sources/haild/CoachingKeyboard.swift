import Darwin
import Foundation

/// Exclusive owner-local feedback. Backpressure is an error, never an actor-blocking wait or queued effect.
@MainActor final class CoachingTerminal {
    private var descriptor: Int32?
    convenience init(output: Int32 = STDERR_FILENO) throws {
        try self.init(output: output, requireTerminal: true)
    }
    private init(output: Int32, requireTerminal: Bool) throws {
        var original = stat()
        guard fstat(output, &original) == 0 else { throw CoachingCommandError.localControlRequired }
        let fd: Int32
        if isatty(output) == 1 {
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard ttyname_r(output, &path, path.count) == 0 else {
                throw CoachingCommandError.localControlRequired
            }
            fd = path.withUnsafeBufferPointer {
                guard let base = $0.baseAddress else { return -1 }
                return Darwin.open(base, O_WRONLY | O_NONBLOCK | O_NOCTTY)
            }
            var opened = stat()
            guard fd >= 0, fstat(fd, &opened) == 0, opened.st_dev == original.st_dev,
                  opened.st_ino == original.st_ino, opened.st_rdev == original.st_rdev else {
                if fd >= 0 { Darwin.close(fd) }; throw CoachingCommandError.localControlRequired
            }
        } else {
            // A dup shares file-status flags. Only an already nonblocking pipe is safe for redirected feedback.
            guard !requireTerminal, original.st_mode & S_IFMT == S_IFIFO,
                  fcntl(output, F_GETFL) & O_NONBLOCK != 0 else {
                throw CoachingCommandError.localControlRequired
            }
            fd = dup(output)
        }
        guard fd >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            if fd >= 0 { Darwin.close(fd) }; throw CoachingCommandError.localControlRequired
        }
        descriptor = fd
    }
    /// The final CLI diagnostic must not re-enter ordinary blocking stderr after owned retirement.
    static func reportRefusal(output: Int32 = STDERR_FILENO) {
        guard let terminal = try? CoachingTerminal(output: output, requireTerminal: false) else { return }
        defer { terminal.close() }
        try? terminal.write("haild: private coaching refused; use trusted local terminal controls"
                            + " and explicit private configuration\n")
    }
    isolated deinit { close() }
    func close() {
        guard let fd = descriptor else { return }
        descriptor = nil
        Darwin.close(fd)
    }
    func write(_ text: String) throws {
        let bytes = Data(text.utf8)
        guard let fd = descriptor, !bytes.isEmpty, bytes.count <= 512,
              bytes.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else {
            throw CoachingCommandError.invalidControl
        }
        for _ in 0..<2 {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count == bytes.count { return }
            if count < 0, errno == EINTR { continue }
            break // Partial/EAGAIN/error cannot delay authority retirement or retain queued feedback.
        }
        throw CoachingCommandError.invalidControl
    }
}

/// Bounded exclusive terminal control reader. Never blocks the foreground renewal/audio actor.
@MainActor final class CoachingKeyboard {
    let lines: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let source: any DispatchSourceRead
    private let descriptor: Int32
    private var signals: [any DispatchSourceSignal] = []
    private var priorSignals: [Int32: sigaction] = [:]
    private let ended: () -> Void
    private var buffer = Data()
    private(set) var closed = false

    init(input: Int32 = STDIN_FILENO, observeSignals: Bool = true, ended: @escaping () -> Void) throws {
        // Atomic close-on-exec: the owner's control input must never reach a spawned child.
        let fd = fcntl(input, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw CoachingCommandError.localControlRequired }
        let pair = AsyncThrowingStream<String, any Error>.makeStream(bufferingPolicy: .bufferingOldest(4))
        lines = pair.stream; continuation = pair.continuation; self.ended = ended
        descriptor = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.read(fd) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.activate()
        for number in observeSignals ? [SIGINT, SIGTERM] : [] {
            var ignored = sigaction(), previous = sigaction()
            ignored.__sigaction_u.__sa_handler = SIG_IGN
            sigemptyset(&ignored.sa_mask)
            guard sigaction(number, &ignored, &previous) == 0 else {
                close(error: true); throw CoachingCommandError.localControlRequired
            }
            priorSignals[number] = previous
            let observer = DispatchSource.makeSignalSource(signal: number, queue: .main)
            observer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.close() } }
            observer.activate(); signals.append(observer)
        }
    }
    isolated deinit {
        source.cancel(); signals.forEach { $0.cancel() }; restoreSignals(); continuation.finish()
    }

    func close(error: Bool = false) {
        guard !closed else { return }
        closed = true
        source.cancel(); signals.forEach { $0.cancel() }; restoreSignals()
        ended() // Clear capture/TTS/child authority synchronously before delivering stream completion.
        if error { continuation.finish(throwing: CoachingCommandError.invalidControl) } else { continuation.finish() }
    }
    /// Drain ready input/EOF before admitting buffered authority; canonical Ctrl-D has no HUP bit.
    func permitsControl() -> Bool {
        read(descriptor)
        return !closed
    }
    private func restoreSignals() {
        let previous = priorSignals
        priorSignals.removeAll()
        for (number, value) in previous {
            var action = value
            _ = sigaction(number, &action, nil)
        }
    }
    private func read(_ fd: Int32) {
        for _ in 0..<8 { // Queue/line bounds normally stop sooner; never monopolize the audio actor.
            guard !closed else { return }
            var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&state, 1, 0)
            if ready == 0 { return }
            guard ready > 0, state.revents & Int16(POLLERR | POLLNVAL) == 0 else { close(error: true); return }
            if state.revents & Int16(POLLHUP) != 0 { close(); return }
            guard state.revents & Int16(POLLIN) != 0 else { close(error: true); return }
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { close(error: count < 0); return }
            accept(bytes.prefix(count))
        }
        close(error: true)
    }
    private func accept(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
                if byte == 10 {
                    guard let line = String(data: buffer, encoding: .ascii) else { close(error: true); return }
                    buffer.removeAll(keepingCapacity: true)
                    switch continuation.yield(line) {
                    case .enqueued: break
                    case .dropped, .terminated: close(error: true); return
                    @unknown default: close(error: true); return
                    }
                } else {
                    guard (32...126).contains(byte), buffer.count < 96 else { close(error: true); return }
                    buffer.append(byte)
                }
            }
    }
}
