#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// Rightyo stdin child (#203): raw mono16k s16le in, JSONL out; fixed argv, no shell, minimal environment.
/// Working directory = config parent. Audio/stdout never logged; stderr discarded with byte count only.
public final class RightyoChildProcess: Sendable {
    public static let maxLineBytes = 1_200_000
    /// Untaken stdout lines are byte bounded, not count bounded; excess ends with `backlog`.
    public static let maxQueuedBytes = 4_000_000
    /// stdout split on newlines (empty lines skipped). Ends at EOF, or throws a `RightyoChildError`.
    public let lines: RightyoChildOutput
    public let processIdentifier: Int32
    let input: RightyoStdinWriter
    let control: RightyoControlWriter
    let coachingControl: RightyoCoachingControlWriter?
    private let outputRevocation: RightyoOutputRevocation?
    /// Owned group (#297): one queue observes exit/signals/reaps, preventing PID reuse.
    private let group: RightyoChildGroup
    private let stderrBytes = RightyoByteCount()
    private let timing: Timing
    /// Fixed validated executable/argv/environment; only RIGHTYO_ additions (#172). Coaching is explicitly opt-in.
    public init(executable: URL, config: URL, session: String, provenance: RightyoAudioProvenance = .liveMicrophone,
                timing: Timing = .init(), replyControl: Bool = false, env: [String: String] = [:],
                coaching: RightyoCoachingLaunch? = nil) throws {
        guard coaching == nil || !replyControl else { throw RightyoChildError.unsafeConfig }
        let extra = try coaching?.arguments(session: session, provenance: provenance) ?? []
        let hasControl = replyControl || coaching != nil
        let resolved = try Self.validate(executable: executable, config: config)
        try RightyoChildGroup.requireOwnedRuntime()
        let argv = Self.arguments(session: session, config: config, provenance: provenance,
                                  replyControl: hasControl) + extra
        let environment = Self.environment().merging(env.filter { $0.key.hasPrefix("RIGHTYO_") }) { old, _ in old }
        let child = try Self.spawn(resolved, arguments: argv, environment: environment.map { "\($0.key)=\($0.value)" },
                                   directory: config.deletingLastPathComponent().path, replyControl: hasControl)
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .unbounded)
        let queued = RightyoByteCount()
        let revocation = coaching == nil ? nil : RightyoOutputRevocation()
        outputRevocation = revocation
        // The leader's exit ends the stream even if a descendant that left the group still holds stdout (#297).
        let continuation = pair.continuation, ended = RightyoByteCount()
        continuation.onTermination = { _ in ended.withLock { $0 = 1 } }
        group = RightyoChildGroup(leader: child.pid, termGrace: timing.termGrace) {
            guard ended.withLock({ $0 }) == 0 else { return false }
            revocation?.ownedGroupEnded()
            continuation.finish(throwing: RightyoChildError.transportLost)
            return true
        }
        input = RightyoStdinWriter(input: child.input, exit: group.exit, timing: timing)
        control = RightyoControlWriter(coaching == nil ? child.control : nil)
        coachingControl = coaching == nil ? nil
            : Self.coachingWriter(child.control, input: input, continuation: continuation, revocation: revocation)
        lines = RightyoChildOutput(base: RightyoChildLines(stream: pair.stream, queued: queued),
                                   revocation: revocation, control: coachingControl)
        (processIdentifier, self.timing) = (child.pid, timing)
        Thread.detachNewThread { RightyoChildLines.read(child.output, into: pair.continuation, queued: queued) }
        Thread.detachNewThread { [stderrBytes] in
            Self.drainErrors(child.errors) { count in stderrBytes.withLock { $0 += count } }
        }
    }

    /// Drop abandons stdin and kills only the owned group, which still reaps.
    deinit {
        outputRevocation?.revoke()
        input.close(abandon: true)
        coachingControl?.close()
        group.signal(SIGKILL)
    }

    public var counters: Counters {
        var counters = input.counters
        counters.stderrBytes = stderrBytes.withLock { $0 }
        return counters
    }
    public var exitStatus: RightyoChildExit? { group.exit.value }
    /// EOF, owned SIGTERM/SIGKILL and reap. Bounded by `eofGrace + 3 * termGrace + 1` (10s by default).
    /// If not settled, returns the observed exit or SIGKILL; the owned supervisor continues cleanup (#366).
    @discardableResult public func stop(eofGrace: TimeInterval? = nil, termGrace: TimeInterval? = nil) async
        -> RightyoChildExit {
        let (eofGrace, termGrace) = (eofGrace ?? timing.eofGrace, termGrace ?? timing.termGrace); closeInput()
        if await group.exit.wait(timeout: eofGrace) == nil {
            group.signal(SIGTERM)
            if await group.exit.wait(timeout: termGrace) == nil { group.signal(SIGKILL) }
        }
        let settled = await group.settled.wait(timeout: 2 * termGrace + 1)
        return settled ?? group.exit.value ?? .signaled(SIGKILL)
    }
}

/// Bounded nonblocking stdin queue (#203); workers hold fd/state/exit only, never retain the child.
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

    /// Every nonblocking write shares abandonment ownership; waiting chunks retain their original age.
    private func push(_ chunk: Data, at: UInt64) -> Bool {
        var offset = 0
        while offset < chunk.count {
            let result = writeOwned(chunk, offset: offset)
            guard let count = result else { return false }
            if count > 0 {
                offset += count
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

    private func writeOwned(_ chunk: Data, offset: Int) -> Int? {
        state.withLock { current in
            guard !current.abandoned, !current.closed else { return nil }
            let count = chunk.withUnsafeBytes {
                Darwin.write(input, $0.baseAddress?.advanced(by: offset), chunk.count - offset)
            }
            if count > 0 { current.counters.writtenBytes += count }
            return count
        }
    }
}
#endif
