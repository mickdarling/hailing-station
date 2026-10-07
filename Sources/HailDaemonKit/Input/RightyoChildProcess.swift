#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// One `rightyo listen --mode stdin` child (#203): raw mono 16 kHz s16le in, JSONL out. Fixed argv, no shell,
/// minimal environment, working directory = the config's directory. Audio and stdout lines are never logged;
/// stderr is drained and only its byte count kept.
public final class RightyoChildProcess: Sendable {
    public static let maxLineBytes = 1_200_000
    /// Lines read but not yet taken are bounded by total bytes only (no line count); past this the stream ends
    /// with `backlog`.
    public static let maxQueuedBytes = 4_000_000
    /// stdout split on newlines (empty lines skipped). Ends at EOF, or throws a `RightyoChildError`.
    public let lines: RightyoChildLines
    public let processIdentifier: Int32
    private let input: RightyoStdinWriter
    /// The child leads its own process group (#297): it observes the exit, signals the group and reaps the leader
    /// on one queue, so a signal can never reach a reused pid.
    private let group: RightyoChildGroup
    private let stderrBytes = RightyoByteCount()
    private let timing: Timing

    /// Launches `<executable> listen --mode stdin --provenance <provenance> --session-id <session> --config <config>`,
    /// spawning exactly the symlink-resolved path that `validate` checked.
    public init(executable: URL, config: URL, session: String, provenance: RightyoAudioProvenance = .liveMicrophone,
                timing: Timing = .init()) throws {
        let resolved = try Self.validate(executable: executable, config: config)
        let argv = Self.arguments(session: session, config: config, provenance: provenance)
        let child = try Self.spawn(resolved, arguments: argv,
                                   environment: Self.environment().map { "\($0.key)=\($0.value)" },
                                   directory: config.deletingLastPathComponent().path)
        // No line-count cap: untaken lines are bounded by `maxQueuedBytes` alone (checked before each yield).
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .unbounded)
        let queued = RightyoByteCount()
        lines = RightyoChildLines(stream: pair.stream, queued: queued)
        // The leader's exit ends the stream even if a descendant that left the group still holds stdout (#297).
        let continuation = pair.continuation
        group = RightyoChildGroup(leader: child.pid, termGrace: timing.termGrace) {
            continuation.finish(throwing: RightyoChildError.transportLost)
        }
        input = RightyoStdinWriter(input: child.input, exit: group.exit, timing: timing)
        (processIdentifier, self.timing) = (child.pid, timing)
        // No background thread or queue retains `self` (stdin writer, stdout reader, stderr drain, group, exit
        // waiters each hold only their own box), so dropping the last reference runs `deinit` and kills the child.
        Thread.detachNewThread { RightyoChildLines.read(child.output, into: pair.continuation, queued: queued) }
        Thread.detachNewThread { [stderrBytes] in
            Self.drainErrors(child.errors) { count in stderrBytes.withLock { $0 += count } }
        }
    }

    /// Dropped without `stop()`: stdin abandoned and SIGKILL to the whole group at once; the group still reaps.
    deinit {
        input.close(abandon: true)
        group.signal(SIGKILL)
    }

    public var counters: Counters {
        var counters = input.counters
        counters.stderrBytes = stderrBytes.withLock { $0 }
        return counters
    }
    public var exitStatus: RightyoChildExit? { group.exit.value }

    /// Queues one audio chunk and returns at once; never blocks on the child. False when input is closed or the
    /// chunk is empty, odd-length (not whole samples) or larger than the backlog.
    @discardableResult public func write(_ pcm: Data) -> Bool { input.write(pcm) }

    /// EOF for the child once already-queued audio is written. Idempotent.
    public func closeInput() { input.close(abandon: false) }

    /// Close stdin, wait `eofGrace`, SIGTERM the group, wait `termGrace`, SIGKILL the group; returns once the rest
    /// of the group has been ended too (see `RightyoChildGroup`) and the child is reaped.
    @discardableResult public func stop() async -> RightyoChildExit {
        closeInput()
        if await group.exit.wait(timeout: timing.eofGrace) == nil {
            group.signal(SIGTERM)
            if await group.exit.wait(timeout: timing.termGrace) == nil { group.signal(SIGKILL) }
        }
        return await group.settled.wait(timeout: nil) ?? .signaled(SIGKILL)
    }
}

/// The child's stdin (#203): a bounded queue drained on its own serial queue with non-blocking writes. It holds
/// only the fd, its own state and the exit latch, never the child, so a stalled child cannot keep its owner alive.
final class RightyoStdinWriter: Sendable {
    private struct State {
        var queue = RightyoChunkQueue(), queued = 0, counters = RightyoChildProcess.Counters()
        var writing = false, closing = false, closed = false, abandoned = false
    }
    private let input: Int32
    private let state = Mutex(State())
    private let exit: RightyoExitLatch
    private let timing: RightyoChildProcess.Timing
    private let writer = DispatchQueue(label: "hailing.rightyo-child.stdin")

    init(input: Int32, exit: RightyoExitLatch, timing: RightyoChildProcess.Timing) {
        (self.input, self.exit, self.timing) = (input, exit, timing)
    }

    var counters: RightyoChildProcess.Counters { state.withLock { $0.counters } }

    func write(_ pcm: Data) -> Bool {
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

    /// EOF after queued audio, or with `abandon` at once: pending audio is dropped and an in-flight write gives up.
    func close(abandon: Bool) {
        state.withLock { state in
            state.closing = true
            if abandon { state.abandoned = true }
            if !state.writing, !state.closed { state.closed = true; Darwin.close(input) }
        }
    }

    private static func dropOldest(_ state: inout State) {
        let dropped = state.queue.removeFirst().data.count
        state.queued -= dropped
        state.counters.droppedChunks += 1
        state.counters.droppedBytes += dropped
    }

    private func drain() {
        while let (chunk, at) = next() {
            guard push(chunk, at: at) else {
                state.withLock { state in
                    while !state.queue.isEmpty { Self.dropOldest(&state) }
                    (state.closing, state.writing) = (true, false)
                    if !state.closed { state.closed = true; Darwin.close(input) }
                }
                return
            }
        }
    }

    private func next() -> (Data, UInt64)? {
        state.withLock { state in
            let limit = UInt64(timing.backlogAge * 1e9), now = DispatchTime.now().uptimeNanoseconds
            while let first = state.queue.first, now - first.at > limit { Self.dropOldest(&state) }
            if state.abandoned { while !state.queue.isEmpty { Self.dropOldest(&state) } }
            guard !state.queue.isEmpty else {
                state.writing = false
                if state.closing, !state.closed { state.closed = true; Darwin.close(input) }
                return nil
            }
            let chunk = state.queue.removeFirst()
            state.queued -= chunk.data.count
            return chunk
        }
    }

    /// Non-blocking writes with `F_SETNOSIGPIPE`: a dead child is EPIPE, never a signal. A chunk waiting on a full
    /// pipe ages like a queued one: past `backlogAge` its unsent rest (from a sample boundary) is dropped.
    private func push(_ chunk: Data, at: UInt64) -> Bool {
        var offset = 0
        while offset < chunk.count {
            let count = chunk.withUnsafeBytes {
                Darwin.write(input, $0.baseAddress?.advanced(by: offset), chunk.count - offset)
            }
            if count > 0 {
                offset += count
                state.withLock { $0.counters.writtenBytes += count }
            } else if count < 0, errno == EINTR { continue } else {
                guard count < 0, errno == EAGAIN, exit.value == nil, !state.withLock({ $0.abandoned }) else {
                    return false
                }
                let age = DispatchTime.now().uptimeNanoseconds - at
                if offset.isMultiple(of: 2), age > UInt64(timing.backlogAge * 1e9) {
                    state.withLock { $0.counters.droppedChunks += 1; $0.counters.droppedBytes += chunk.count - offset }
                    return true
                }
                var ready = pollfd(fd: input, events: Int16(POLLOUT), revents: 0)
                _ = poll(&ready, 1, 100)
            }
        }
        return true
    }
}
#endif
