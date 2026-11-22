#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// Bounded nonblocking stdin queue (#203); workers hold fd/state/exit only, never retain the child.
final class RightyoStdinWriter: Sendable {
    private struct State {
        var queue = RightyoPrefixedQueue(), queued = 0, counters = RightyoChildProcess.Counters()
        var epoch = 0, discardBefore = 0
        var needsAlignment = false
        var drained: (@Sendable () -> Void)?
        var writing = false, closing = false, closed = false, abandoned = false, failed = false

        mutating func discard(_ item: RightyoPrefixedQueue.Item, from offset: Int = 0) {
            counters.droppedChunks += 1
            counters.droppedBytes += item.data.count - max(offset, item.silence)
        }
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
            state.queue.append(.init(epoch: state.epoch, data: chunk, at: DispatchTime.now().uptimeNanoseconds,
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

    enum Boundary { case closed, ready, pending(Int) }

    func afterQueued(_ drained: @escaping @Sendable () -> Void) -> Boundary {
        state.withLock { current in
            guard !current.closing, !current.failed, exit.value == nil else { return .closed }
            guard current.writing else { return .ready }
            current.epoch += 1
            current.drained = drained
            return .pending(current.epoch)
        }
    }

    /// Invalidate the old epochs under the same ownership as each nonblocking stdin write.
    func finishBoundary(discardBefore epoch: Int?) -> Bool {
        state.withLock { current in
            guard !current.closing, !current.failed, exit.value == nil else { return false }
            if let epoch { current.discardBefore = epoch }
            return true
        }
    }

    private static func dropOldest(_ state: inout State) {
        let item = state.queue.removeFirst()
        state.queued -= item.data.count
        state.discard(item)
    }
    private func drain() {
        while let work = next() {
            switch work {
            case .boundary(let drained): drained()
            case .audio(let item):
                guard push(item) else { stopAfterFailure(); return }
            }
        }
    }

    private func stopAfterFailure() {
        state.withLock { state in
            fail(&state)
            while !state.queue.isEmpty { Self.dropOldest(&state) }
            (state.closing, state.writing) = (true, false)
            if !state.closed { state.closed = true; Darwin.close(input) }
        }
    }

    private enum Work { case audio(RightyoPrefixedQueue.Item), boundary(@Sendable () -> Void) }

    private func next() -> Work? {
        state.withLock { state in
            let limit = UInt64(timing.backlogAge * 1e9), now = DispatchTime.now().uptimeNanoseconds
            while let first = state.queue.first, now - first.at > limit { Self.dropOldest(&state) }
            if state.abandoned { while !state.queue.isEmpty { Self.dropOldest(&state) } }
            let nextEpoch = state.queue.first?.epoch ?? state.epoch
            if let drained = state.drained, nextEpoch == state.epoch {
                state.drained = nil
                return .boundary(drained)
            }
            guard !state.queue.isEmpty else {
                state.writing = false
                if state.closing, !state.closed { state.closed = true; Darwin.close(input) }
                return nil
            }
            let chunk = state.queue.removeFirst()
            state.queued -= chunk.data.count
            return .audio(chunk)
        }
    }
}

extension RightyoStdinWriter {
    private func push(_ item: RightyoPrefixedQueue.Item) -> Bool {
        var offset = 0
        while offset < item.data.count {
            switch writeOwned(item, offset: offset) {
            case .discarded: return true
            case .closed: return false
            case .advanced(let count): offset += count
            case .interrupted: continue
            case .blocked:
                guard exit.value == nil, !state.withLock({ $0.abandoned }) else { return false }
                let age = DispatchTime.now().uptimeNanoseconds - item.at
                if offset.isMultiple(of: 2), age > UInt64(timing.backlogAge * 1e9) {
                    state.withLock { $0.discard(item, from: offset) }
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

    private enum WriteResult { case discarded, closed, advanced(Int), interrupted, blocked }

    private func writeOwned(_ item: RightyoPrefixedQueue.Item, offset: Int) -> WriteResult {
        state.withLock { current in
            guard !current.abandoned, !current.closed, !current.failed else { return .closed }
            guard item.epoch >= current.discardBefore else {
                current.discard(item, from: offset)
                if !offset.isMultiple(of: 2) { current.needsAlignment = true }
                return .discarded
            }
            // Complete a truncated sample with zero before starting the next retained sample.
            if current.needsAlignment {
                var padding: UInt8 = 0
                let count = Darwin.write(input, &padding, 1)
                guard count == 1 else { return refusedWrite(count, in: &current) }
                current.needsAlignment = false
            }
            let count = item.data.withUnsafeBytes {
                Darwin.write(input, $0.baseAddress?.advanced(by: offset), item.data.count - offset)
            }
            // Existing public counters describe real PCM only, even for a partial prefix write.
            guard count > 0 else { return refusedWrite(count, in: &current) }
            current.counters.writtenBytes += max(0, offset + count - max(offset, item.silence))
            return .advanced(count)
        }
    }

    private func refusedWrite(_ count: Int, in current: inout State) -> WriteResult {
        if count < 0, errno == EINTR { return .interrupted }
        if count < 0, errno == EAGAIN { return .blocked }
        fail(&current)
        return .closed
    }
}
#endif
