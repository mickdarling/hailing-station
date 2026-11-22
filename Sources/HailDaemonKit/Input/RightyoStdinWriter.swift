#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// Bounded nonblocking stdin queue (#203); workers hold fd/state/exit only, never retain the child.
final class RightyoStdinWriter: Sendable {
    struct State {
        var queue = RightyoPrefixedQueue(), queued = 0, counters = RightyoChildProcess.Counters()
        var epoch = 0, discardBefore = 0
        var needsAlignment = false
        var reserved = false, knownPublic = false, ordersAudio = true, inFlight: Int?
        var fencesAudio: Bool { reserved && ordersAudio }
        var through = -1, handed = -1, discardedThrough = -1, prefixCount = 0
        var writing = false, closing = false, closed = false, abandoned = false, failed = false

        mutating func discard(_ item: RightyoPrefixedQueue.Item, from offset: Int = 0) {
            counters.droppedChunks += 1
            counters.droppedBytes += item.data.count - max(offset, item.silence)
        }
    }
    private let input: Int32
    let state: Mutex<State>
    let exit: RightyoExitLatch
    private let timing: RightyoChildProcess.Timing
    private let onFailure: @Sendable () -> Void
    private let writer: DispatchQueue
    struct Endpoint { let descriptor: Int32, startPrivate: Bool }
    init(input: Endpoint, exit: RightyoExitLatch, timing: RightyoChildProcess.Timing,
         writer: DispatchQueue = DispatchQueue(label: "hailing.rightyo-child.stdin"),
         failed: @escaping @Sendable () -> Void = {}) {
        state = Mutex(State(knownPublic: !input.startPrivate))
        (self.input, self.exit, self.timing) = (input.descriptor, exit, timing); onFailure = failed
        self.writer = writer
    }

    var counters: RightyoChildProcess.Counters { state.withLock { $0.counters } }
    enum Enqueue { case accepted, discarded, closed }

    func enqueue(_ pcm: Data, leadingSilenceBytes: Int, admission: Int?) -> Enqueue {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= timing.backlogBytes else { return .closed }
        guard (0...AmbientGapFill.maxBytes).contains(leadingSilenceBytes),
              leadingSilenceBytes.isMultiple(of: AmbientGapFill.chunkBytes) else { return .closed }
        // One queue item: silence cannot be reordered or evicted separately from its following PCM.
        var chunk = pcm
        if leadingSilenceBytes > 0 {
            chunk = Data(repeating: 0, count: leadingSilenceBytes)
            chunk.append(pcm)
        }
        let (accepted, start) = state.withLock { state -> (Enqueue, Bool) in
            guard !state.closing, !state.failed else { return (.closed, false) }
            if let admission {
                state.handed = max(state.handed, admission)
                if admission <= state.discardedThrough {
                    state.counters.droppedBytes += pcm.count
                    state.counters.droppedChunks += 1
                    return (.discarded, false)
                }
            }
            let before = state.fencesAudio && admission.map { $0 <= state.through } == true
            if before { state.prefixCount += 1 }
            state.queue.append(.init(epoch: before ? state.epoch - 1 : state.epoch, data: chunk,
                                     at: DispatchTime.now().uptimeNanoseconds, silence: leadingSilenceBytes))
            state.queued += chunk.count
            // Only queued prefixes reserve space; taking or evicting the last one restores the PCM budget.
            while state.queued > timing.backlogBytes + state.queue.silenceAllowance { Self.dropOldest(&state) }
            defer { state.writing = true }
            return (.accepted, !state.writing)
        }
        if start { writer.async { self.drain() } }
        return accepted
    }

    /// EOF after queued audio, or with `abandon` at once: pending audio is dropped and an in-flight write gives up.
    func close(abandon: Bool) {
        state.withLock { state in
            state.closing = true
            if abandon { state.abandoned = true }
            if state.reserved { release(&state) }
            if !state.writing, !state.closed { state.closed = true; Darwin.close(input) }
        }
    }

    func release(_ current: inout State) {
        current.reserved = false
        if !current.writing, !current.queue.isEmpty {
            current.writing = true
            writer.async { self.drain() }
        }
    }
}

extension RightyoStdinWriter {
    private static func dropOldest(_ state: inout State) {
        let item = state.queue.removeFirst()
        if state.fencesAudio, item.epoch < state.epoch { state.prefixCount -= 1 }
        state.queued -= item.data.count
        state.discard(item)
    }
    private func drain() {
        while let item = next() {
            guard push(item) else { stopAfterFailure(); return }
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

    private func next() -> RightyoPrefixedQueue.Item? {
        state.withLock { state in
            let limit = UInt64(timing.backlogAge * 1e9), now = DispatchTime.now().uptimeNanoseconds
            while let first = state.queue.first, now - first.at > limit { Self.dropOldest(&state) }
            if state.abandoned { while !state.queue.isEmpty { Self.dropOldest(&state) } }
            state.inFlight = nil
            guard let first = state.queue.first,
                  state.closing || !state.fencesAudio || first.epoch < state.epoch else {
                state.writing = false
                if state.closing, !state.closed { state.closed = true; Darwin.close(input) }
                return nil
            }
            let chunk = state.queue.removeFirst()
            if state.fencesAudio, chunk.epoch < state.epoch { state.prefixCount -= 1 }
            state.queued -= chunk.data.count
            state.inFlight = chunk.epoch
            return chunk
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
