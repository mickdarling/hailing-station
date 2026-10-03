#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// Why the RightyO child refused to start or its output ended (#203). Cases name rules, never content.
public enum RightyoChildError: Error, Sendable, Equatable {
    /// Not absolute, not a regular file, not executable, or group/world-writable.
    case unsafeExecutable
    /// Not absolute or not a regular readable file.
    case unsafeConfig
    /// A stdout line passed `maxLineBytes` before its newline; `backlog`: more lines waited than were taken.
    case lineTooLong, backlog, transportLost
}

/// How a reaped child ended.
public enum RightyoChildExit: Sendable, Equatable { case exited(Int32), signaled(Int32) }

/// One `rightyo listen --mode stdin` child (#203): raw mono 16 kHz s16le in, JSONL out. Fixed argv, no shell,
/// minimal environment, working directory = the config's directory. Audio and stdout lines are never logged;
/// stderr is drained and only its byte count kept.
public final class RightyoChildProcess: Sendable {
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
    private struct State {
        var queue: [(data: Data, at: UInt64)] = [], queued = 0, counters = Counters()
        var writing = false, closing = false, closed = false
    }
    public static let maxLineBytes = 1_200_000
    /// Lines read but not yet taken are bounded in bytes too; past this the stream ends with `backlog`.
    public static let maxQueuedBytes = 4_000_000
    /// stdout split on newlines (empty lines skipped). Ends at EOF, or throws a `RightyoChildError`.
    public let lines: RightyoChildLines
    public let processIdentifier: Int32
    private let input: Int32
    private let state = Mutex(State())
    private let exit = RightyoExitLatch()
    private let stderrBytes = RightyoByteCount()
    private let timing: Timing
    private let writer = DispatchQueue(label: "hailing.rightyo-child.stdin")
    /// Reaps the child and sends every signal, so a signal can never reach a reused pid.
    private let reaper = DispatchQueue(label: "hailing.rightyo-child.reap")

    /// Launches `<executable> listen --mode stdin --provenance <provenance> --session-id <session> --config <config>`.
    public init(executable: URL, config: URL, session: String, provenance: RightyoAudioProvenance = .liveMicrophone,
                timing: Timing = .init()) throws {
        try Self.validate(executable: executable, config: config)
        let argv = Self.arguments(session: session, config: config, provenance: provenance)
        let child = try Self.spawn(executable.path, arguments: argv,
                                   environment: Self.environment().map { "\($0.key)=\($0.value)" },
                                   directory: config.deletingLastPathComponent().path)
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let queued = RightyoByteCount()
        lines = RightyoChildLines(stream: pair.stream, queued: queued)
        (processIdentifier, input, self.timing) = (child.pid, child.input, timing)
        let source = DispatchSource.makeProcessSource(identifier: child.pid, eventMask: .exit, queue: reaper)
        source.setEventHandler { [exit] in if Self.reap(child.pid, into: exit, blocking: true) { source.cancel() } }
        source.activate()
        reaper.async { [exit] in if Self.reap(child.pid, into: exit, blocking: false) { source.cancel() } }
        Thread.detachNewThread { RightyoChildLines.read(child.output, into: pair.continuation, queued: queued) }
        // No reader thread retains `self`, so dropping the last reference runs `deinit` and kills the child.
        Thread.detachNewThread { [stderrBytes] in
            Self.drainErrors(child.errors) { count in stderrBytes.withLock { $0 += count } }
        }
    }

    /// Dropped without `stop()`: EOF and SIGKILL at once; the exit source still reaps the child.
    deinit {
        state.withLock { if !$0.closed, !$0.writing { $0.closed = true; close(input) } }
        signal(SIGKILL)
    }

    public var counters: Counters {
        var counters = state.withLock { $0.counters }
        counters.stderrBytes = stderrBytes.withLock { $0 }
        return counters
    }
    public var exitStatus: RightyoChildExit? { exit.value }

    /// Queues one audio chunk and returns at once; never blocks on the child. False when input is closed or the
    /// chunk is empty, odd-length (not whole samples) or larger than the backlog.
    @discardableResult public func write(_ pcm: Data) -> Bool {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= timing.backlogBytes else { return false }
        let (accepted, start) = state.withLock { state -> (Bool, Bool) in
            guard !state.closing else { return (false, false) }
            state.queue.append((pcm, DispatchTime.now().uptimeNanoseconds))
            state.queued += pcm.count
            while state.queued > timing.backlogBytes { Self.dropOldest(&state) }
            defer { state.writing = true }
            return (true, !state.writing)
        }
        if start { writer.async { self.drain() } }
        return accepted
    }

    /// EOF for the child once already-queued audio is written. Idempotent.
    public func closeInput() {
        state.withLock { state in
            state.closing = true
            if !state.writing, !state.closed { state.closed = true; close(input) }
        }
    }

    /// Close stdin, wait `eofGrace`, SIGTERM, wait `termGrace`, SIGKILL; returns once the child is reaped.
    @discardableResult public func stop() async -> RightyoChildExit {
        closeInput()
        if let done = await exit.wait(timeout: timing.eofGrace) { return done }
        signal(SIGTERM)
        if let done = await exit.wait(timeout: timing.termGrace) { return done }
        signal(SIGKILL)
        return await exit.wait(timeout: nil) ?? .signaled(SIGKILL)
    }

    private func signal(_ value: Int32) {
        reaper.sync { if exit.value == nil { _ = kill(processIdentifier, value) } }
    }

    private static func dropOldest(_ state: inout State) {
        let dropped = state.queue.removeFirst().data.count
        state.queued -= dropped
        state.counters.droppedChunks += 1
        state.counters.droppedBytes += dropped
    }

    private func drain() {
        while let chunk = next() {
            guard push(chunk) else {
                state.withLock { state in
                    while !state.queue.isEmpty { Self.dropOldest(&state) }
                    (state.closing, state.writing) = (true, false)
                    if !state.closed { state.closed = true; close(input) }
                }
                return
            }
        }
    }

    private func next() -> Data? {
        state.withLock { state in
            let limit = UInt64(timing.backlogAge * 1e9), now = DispatchTime.now().uptimeNanoseconds
            while let first = state.queue.first, now - first.at > limit { Self.dropOldest(&state) }
            guard !state.queue.isEmpty else {
                state.writing = false
                if state.closing, !state.closed { state.closed = true; close(input) }
                return nil
            }
            let chunk = state.queue.removeFirst().data
            state.queued -= chunk.count
            return chunk
        }
    }

    /// Non-blocking writes with `F_SETNOSIGPIPE`: a dead child is EPIPE, never a signal.
    private func push(_ chunk: Data) -> Bool {
        var offset = 0
        while offset < chunk.count {
            let count = chunk.withUnsafeBytes {
                Darwin.write(input, $0.baseAddress?.advanced(by: offset), chunk.count - offset)
            }
            if count > 0 {
                offset += count
                state.withLock { $0.counters.writtenBytes += count }
            } else if count < 0, errno == EINTR { continue } else {
                guard count < 0, errno == EAGAIN, exit.value == nil else { return false }
                var ready = pollfd(fd: input, events: Int16(POLLOUT), revents: 0)
                _ = poll(&ready, 1, 100)
            }
        }
        return true
    }
}
#endif
