#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// Bounded nonblocking stdin queue (#203); workers hold fd/state/exit only, never retain the child.
final class RightyoStdinWriter: Sendable {
    private struct State {
        var queue = RightyoPrefixedQueue(), queued = 0, counters = RightyoChildProcess.Counters()
        var writing = false, closing = false, closed = false, abandoned = false, failed = false
    }
    private let input: Int32
    private let state = Mutex(State())
    private let exit: RightyoExitLatch
    private let timing: RightyoChildProcess.Timing
    private let onFailure: @Sendable () -> Void
    private let writer: DispatchQueue
    init(input: Int32, exit: RightyoExitLatch, timing: RightyoChildProcess.Timing,
         writer: DispatchQueue = DispatchQueue(label: "hailing.rightyo-child.stdin"),
         failed: @escaping @Sendable () -> Void = {}) {
        (self.input, self.exit, self.timing) = (input, exit, timing); onFailure = failed
        self.writer = writer
    }

    var counters: RightyoChildProcess.Counters { state.withLock { $0.counters } }
    func write(_ pcm: Data, leadingSilenceBytes: Int = 0) -> Bool {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= timing.backlogBytes else { return false }
        guard (0...AmbientGapFill.maxBytes).contains(leadingSilenceBytes),
              leadingSilenceBytes.isMultiple(of: AmbientGapFill.chunkBytes) else { return false }
        // One queue item: silence cannot be reordered or evicted separately from its following PCM.
        var chunk = pcm
        if leadingSilenceBytes > 0 {
            chunk = Data(repeating: 0, count: leadingSilenceBytes)
            chunk.append(pcm)
        }
        let (accepted, start) = state.withLock { state -> (Bool, Bool) in
            guard !state.closing, !state.failed else { return (false, false) }
            state.queue.append(.init(data: chunk, at: DispatchTime.now().uptimeNanoseconds,
                                     silence: leadingSilenceBytes))
            state.queued += chunk.count
            // Only queued prefixes reserve space; taking or evicting the last one restores the PCM budget.
            while state.queued > timing.backlogBytes + state.queue.silenceAllowance { Self.dropOldest(&state) }
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
        let item = state.queue.removeFirst()
        state.queued -= item.data.count
        let dropped = item.data.count - item.silence
        state.counters.droppedChunks += 1
        state.counters.droppedBytes += dropped
    }
    private func drain() {
        while let item = next() {
            guard push(item) else {
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

    private func next() -> RightyoPrefixedQueue.Item? {
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
    private func push(_ item: RightyoPrefixedQueue.Item) -> Bool {
        let chunk = item.data, at = item.at
        var offset = 0
        while offset < chunk.count {
            let result = writeOwned(chunk, offset: offset, silence: item.silence)
            guard let count = result else { return false }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR { continue } else {
                guard count < 0, errno == EAGAIN, exit.value == nil, !state.withLock({ $0.abandoned }) else {
                    return false
                }
                let age = DispatchTime.now().uptimeNanoseconds - at
                if offset.isMultiple(of: 2), age > UInt64(timing.backlogAge * 1e9) {
                    state.withLock {
                        $0.counters.droppedChunks += 1
                        $0.counters.droppedBytes += chunk.count - max(offset, item.silence)
                    }
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

    private func writeOwned(_ chunk: Data, offset: Int, silence: Int) -> Int? {
        state.withLock { current in
            guard !current.abandoned, !current.closed, !current.failed else { return nil }
            let count = chunk.withUnsafeBytes {
                Darwin.write(input, $0.baseAddress?.advanced(by: offset), chunk.count - offset)
            }
            // Existing public counters describe real PCM only, even for a partial prefix write.
            if count > 0 { current.counters.writtenBytes += max(0, offset + count - max(offset, silence)) }
            if count < 0, errno != EINTR, errno != EAGAIN {
                let saved = errno; fail(&current); errno = saved
            }
            return count
        }
    }
}

/// FIFO metadata beside each PCM item; no-gap Data keeps its original storage. O(1) amortised removal.
private struct RightyoPrefixedQueue {
    struct Item {
        let data: Data
        let at: UInt64
        let silence: Int
    }
    private var items: [Item?] = [], head = 0
    private var prefixes: [Int: Int] = [:]
    var silenceAllowance: Int { prefixes.keys.max() ?? 0 } // At most 30 whole-slice prefix sizes.
    var isEmpty: Bool { head == items.count }
    var first: Item? { isEmpty ? nil : items[head] }
    mutating func append(_ item: Item) {
        items.append(item)
        if item.silence > 0 { prefixes[item.silence, default: 0] += 1 }
    }
    mutating func removeFirst() -> Item {
        guard let item = items[head] else { preconditionFailure("stdin slot already taken") }
        if item.silence > 0 {
            let remaining = (prefixes[item.silence] ?? 1) - 1
            prefixes[item.silence] = remaining == 0 ? nil : remaining
        }
        (items[head], head) = (nil, head + 1)
        if isEmpty { items.removeAll(keepingCapacity: true); head = 0 } else if head >= items.count - head {
            items.removeFirst(head); head = 0
        }
        return item
    }
}

/// Host duration pinned to AmbientAudioFormat.chunkBytes by the cross-module format test.
struct AmbientGapFill: Sendable, Equatable {
    static let chunkBytes = 3_200
    static let maxSegments = 30
    static let maxBytes = chunkBytes * maxSegments
    let missing: Int
    let segments: Int
    var bytes: Int { segments * Self.chunkBytes }
    var detail: String {
        "missing=\(missing) filled_ms=\(segments * 100) capped=\(segments < missing)"
    }

    init?(after last: Int?, sequence: Int, budget: Duration) {
        guard let last, last >= 0, sequence > last, sequence - last > 1 else { return nil }
        missing = sequence - last - 1
        let available = max(.zero, min(.seconds(3), budget)).components
        // Integer floor, never ceil: even a tiny positive elapsed time cannot buy a 100 ms slice.
        let slices = Int(available.seconds * 10 + available.attoseconds / 100_000_000_000_000_000)
        segments = min(missing, slices)
    }
}

#endif
