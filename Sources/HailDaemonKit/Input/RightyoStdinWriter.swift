#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// Bounded nonblocking stdin queue (#203); workers hold fd/state/exit only, never retain the child.
final class RightyoStdinWriter: Sendable {
    private struct State {
        var queue = RightyoChunkQueue(), queued = 0, counters = RightyoChildProcess.Counters()
        var writing = false, closing = false, closed = false, abandoned = false, failed = false
        var silenceAllowance = 0
    }
    private let input: Int32
    private let state = Mutex(State())
    private let exit: RightyoExitLatch
    private let timing: RightyoChildProcess.Timing
    private let onFailure: @Sendable () -> Void
    private let writer = DispatchQueue(label: "hailing.rightyo-child.stdin")
    init(input: Int32, exit: RightyoExitLatch, timing: RightyoChildProcess.Timing,
         failed: @escaping @Sendable () -> Void = {}) {
        (self.input, self.exit, self.timing) = (input, exit, timing); onFailure = failed
    }

    var counters: RightyoChildProcess.Counters { state.withLock { $0.counters } }
    func write(_ pcm: Data, leadingSilenceBytes: Int = 0) -> Bool {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= timing.backlogBytes else { return false }
        guard (0...AmbientGapFill.maxBytes).contains(leadingSilenceBytes),
              leadingSilenceBytes.isMultiple(of: 2) else { return false }
        // One queue item: silence cannot be reordered or evicted separately from its following PCM.
        var chunk = Data(repeating: 0, count: leadingSilenceBytes)
        chunk.append(pcm)
        let (accepted, start) = state.withLock { state -> (Bool, Bool) in
            guard !state.closing, !state.failed else { return (false, false) }
            state.queue.append((chunk, DispatchTime.now().uptimeNanoseconds))
            state.queued += chunk.count
            // Retain a bounded reserve for this child's largest prefix, so the next ordinary segment cannot
            // immediately evict a full 3 s fill merely by reverting to the smaller PCM-only budget.
            state.silenceAllowance = max(state.silenceAllowance, leadingSilenceBytes)
            while state.queued > timing.backlogBytes + state.silenceAllowance { Self.dropOldest(&state) }
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
                    fail(&state)
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

    // This fixed callback only revokes output/finishes its stream; it never re-enters the input writer.
    private func fail(_ current: inout State) {
        guard !current.failed else { return }
        current.failed = true; onFailure()
    }

    private func writeOwned(_ chunk: Data, offset: Int) -> Int? {
        state.withLock { current in
            guard !current.abandoned, !current.closed, !current.failed else { return nil }
            let count = chunk.withUnsafeBytes {
                Darwin.write(input, $0.baseAddress?.advanced(by: offset), chunk.count - offset)
            }
            if count > 0 { current.counters.writtenBytes += count }
            if count < 0, errno != EINTR, errno != EAGAIN {
                let saved = errno; fail(&current); errno = saved
            }
            return count
        }
    }
}

/// Host-side canonical duration; HailDaemonKit deliberately has no dependency on the terminal's HailCore.
/// A cross-module test pins this to AmbientAudioFormat.chunkBytes (16 kHz mono PCM16, 100 ms).
struct AmbientGapFill: Sendable, Equatable {
    static let chunkBytes = 3_200
    static let maxSegments = 30
    static let maxBytes = chunkBytes * maxSegments
    let missing: Int
    var bytes: Int { min(missing, Self.maxSegments) * Self.chunkBytes }
    var detail: String {
        "missing=\(missing) filled_ms=\(min(missing, Self.maxSegments) * 100) capped=\(missing > Self.maxSegments)"
    }

    init?(after last: Int?, sequence: Int) {
        guard let last, last >= 0, sequence > last, sequence - last > 1 else { return nil }
        // Subtract before multiplying, and cap before any multiplication: Int.max is safe.
        missing = sequence - last - 1
    }
}
#endif
