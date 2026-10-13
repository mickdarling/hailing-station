import Darwin
import Foundation

/// Exclusive owner-local feedback. Backpressure is an error, never an actor-blocking wait or queued effect.
@MainActor final class CoachingTerminal {
    private var descriptor: Int32?
    private let flags: Int32
    private let noSigPipe: Int32
    convenience init(output: Int32 = STDERR_FILENO) throws {
        try self.init(output: output, requireTerminal: true)
    }
    private init(output: Int32, requireTerminal: Bool) throws {
        var details = stat()
        let terminal = isatty(output) == 1
        // Nonblocking flags do not bound regular-file/device writes. Final redirected feedback is
        // best-effort only on a pipe; unsupported destinations are silent rather than blocking exit.
        guard terminal || (!requireTerminal && fstat(output, &details) == 0
                           && details.st_mode & S_IFMT == S_IFIFO) else {
            throw CoachingCommandError.localControlRequired
        }
        let fd = dup(output)
        guard fd >= 0 else { throw CoachingCommandError.localControlRequired }
        flags = fcntl(fd, F_GETFL)
        noSigPipe = fcntl(fd, F_GETNOSIGPIPE)
        guard flags >= 0, noSigPipe >= 0, fcntl(fd, F_SETNOSIGPIPE, 1) == 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            if noSigPipe >= 0 { _ = fcntl(fd, F_SETNOSIGPIPE, noSigPipe) }
            Darwin.close(fd); throw CoachingCommandError.localControlRequired
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
        _ = fcntl(fd, F_SETFL, flags) // dup shares status flags; restore the CLI's original nonblocking mode.
        _ = fcntl(fd, F_SETNOSIGPIPE, noSigPipe)
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
    private var signals: [any DispatchSourceSignal] = []
    private let ended: () -> Void
    private var buffer = Data()
    private(set) var closed = false

    init(input: Int32 = STDIN_FILENO, observeSignals: Bool = true, ended: @escaping () -> Void) throws {
        let fd = dup(input)
        guard fd >= 0 else { throw CoachingCommandError.localControlRequired }
        let pair = AsyncThrowingStream<String, any Error>.makeStream(bufferingPolicy: .bufferingOldest(4))
        lines = pair.stream; continuation = pair.continuation; self.ended = ended
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.read(fd) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.activate()
        for number in observeSignals ? [SIGINT, SIGTERM] : [] {
            Darwin.signal(number, SIG_IGN)
            let observer = DispatchSource.makeSignalSource(signal: number, queue: .main)
            observer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.close() } }
            observer.activate(); signals.append(observer)
        }
    }
    isolated deinit { source.cancel(); signals.forEach { $0.cancel() }; continuation.finish() }

    func close(error: Bool = false) {
        guard !closed else { return }
        closed = true
        ended() // Clear capture/TTS/child authority synchronously before delivering stream completion.
        source.cancel(); signals.forEach { $0.cancel() }
        if error { continuation.finish(throwing: CoachingCommandError.invalidControl) } else { continuation.finish() }
    }
    private func read(_ fd: Int32) {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: min(128, max(1, Int(source.data))))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { return }
        guard count > 0 else { close(error: count < 0); return }
        for byte in bytes.prefix(count) {
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
