#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// Coaching failure/abandonment revokes output; explicit graceful EOF preserves buffered terminal lines.
final class RightyoOutputRevocation: Sendable {
    private struct State { var revoked = false, graceful = false; var exit: RightyoExitLatch? }
    private let state = Mutex(State())
    func revoke() { state.withLock { $0.revoked = true } }
    func observe(_ exit: RightyoExitLatch) { state.withLock { $0.exit = exit } }
    func noteGracefulInputClosure() {
        state.withLock {
            guard !$0.graceful else { return }
            if $0.exit?.value != nil { $0.revoked = true } else { $0.graceful = true }
        }
    }
    @discardableResult func ownedGroupEnded() -> Bool {
        state.withLock { if !$0.graceful { $0.revoked = true }; return $0.revoked }
    }
    func check() throws {
        if state.withLock({ $0.revoked }) { throw RightyoChildError.transportLost }
    }
}

/// The existing byte-bounded stdout reader with a coaching-only fence before and after suspension.
public struct RightyoChildOutput: AsyncSequence, Sendable {
    let base: RightyoChildLines
    let revocation: RightyoOutputRevocation?
    let control: RightyoCoachingControlWriter?
    let exit: RightyoExitLatch?
    init(base: RightyoChildLines, revocation: RightyoOutputRevocation?,
         control: RightyoCoachingControlWriter? = nil, exit: RightyoExitLatch? = nil) {
        self.base = base; self.revocation = revocation; self.control = control; self.exit = exit
    }
    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: RightyoChildLines.AsyncIterator
        let revocation: RightyoOutputRevocation?
        let control: RightyoCoachingControlWriter?
        let exit: RightyoExitLatch?
        private func check() throws {
            if exit?.value != nil { revocation?.ownedGroupEnded() }
            try revocation?.check()
            guard control?.peerAvailable() != false else { throw RightyoChildError.transportLost }
        }
        public mutating func next() async throws -> Data? {
            try check()
            let line = try await base.next()
            try check()
            return line
        }
    }
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), revocation: revocation, control: control, exit: exit)
    }
    func revokeCoaching() { revocation?.revoke() }
}

/// What the host reports about the assistant's spoken reply (rightyo#124).
public enum RightyoReplyPhase: String, Sendable { case started, ended }

/// The child's control descriptor (rightyo#124): one short JSON line per report, written without blocking. A line
/// is under `PIPE_BUF`, so each write is atomic: whole, or refused (a full pipe or a gone child) and dropped.
final class RightyoControlWriter: Sendable {
    private let descriptor: Mutex<Int32?>
    private let beforeWrite: (@Sendable () -> Void)?
    init(_ descriptor: Int32?, beforeWrite: (@Sendable () -> Void)? = nil) {
        self.descriptor = Mutex(descriptor)
        self.beforeWrite = beforeWrite
    }
    /// Startup applies the existing wish and preserves an off already reserved behind it.
    func tighten(_ input: RightyoStdinWriter, starting: Bool = false) -> Bool {
        input.tighten(starting: starting) { write("{\"duck\":true}\n") }
    }

    func relax(_ input: RightyoStdinWriter, epoch: Int, expired: Bool) -> RightyoDelivery {
        input.deliver(epoch, expired: expired) { send("{\"duck\":false}\n") }
    }

    func write(_ text: String) -> Bool { send(text) == .delivered }
    private func send(_ text: String) -> RightyoDelivery {
        let line = Array(text.utf8)
        return descriptor.withLock { fd in
            guard let fd else { return .failed }
            beforeWrite?()
            let count = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count == line.count { return .delivered }
            return count < 0 && (errno == EAGAIN || errno == EINTR) ? .pending : .failed
        }
    }
    func close() { descriptor.withLock { fd in if let open = fd { Darwin.close(open) }; fd = nil } }
    deinit { close() }
}

extension RightyoChildProcess {
    /// Nonblocking PCM queue: refuses closed input, empty/odd chunks or chunks above the backlog bound.
    @discardableResult public func write(_ pcm: Data) -> Bool { input.write(pcm) }

    /// Graceful EOF after already-queued PCM; does not revoke buffered terminal output. Idempotent.
    public func closeInput() { control.close(); coachingControl?.close(); input.close(abandon: false) }

    /// Close-on-exec on both ends of a fresh pipe, and its child end moved above every `dup2` target (0-3), so no
    /// `dup2` source is ever a target too: the actions' order cannot matter, and no `dup2` is same-fd (a no-op
    /// that would leave the close-on-exec descriptor closed in the child).
    static func secure(_ ends: inout [Int32], child: Int) -> Bool {
        guard ends.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else { return false }
        let lifted = fcntl(ends[child], F_DUPFD_CLOEXEC, controlDescriptor + 1)
        guard lifted >= 0 else { return false }
        close(ends[child])
        ends[child] = lifted
        return true
    }

    /// When `enabled`, a close-on-exec pipe whose write end never blocks or raises SIGPIPE; true when not enabled.
    static func controlPipe(_ ends: inout [Int32], _ enabled: Bool) -> Bool {
        guard enabled else { return true }
        return pipe(&ends) == 0 && secure(&ends, child: 0)
            && fcntl(ends[1], F_SETNOSIGPIPE, 1) == 0 && fcntl(ends[1], F_SETFL, O_NONBLOCK) == 0
    }
    /// Trusted coaching controls only: one ASCII JSON object without newline. The receiver validates
    /// the exact envelope. Queue admission is not receipt; original host advice deadlines still apply.
    @discardableResult public func sendCoachingControl(_ data: Data, validUntil: ContinuousClock.Instant) -> Bool {
        coachingControl?.send(data, validUntil: validUntil) ?? false
    }

    /// Immediate coaching revocation, not ordinary graceful stdin EOF: discard queued old PCM.
    public func abandonCoachingInput() {
        guard coachingControl != nil else { return }
        lines.revokeCoaching()
        input.close(abandon: true); coachingControl?.close()
    }

    /// Observe the existing owned leader latch even when stdout ended or a descendant retains fd 3.
    static func observeCoachingExit(_ exit: RightyoExitLatch, revocation: RightyoOutputRevocation?,
                                    continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        guard let revocation else { return }
        revocation.observe(exit)
        Task {
            _ = await exit.wait(timeout: nil)
            if revocation.ownedGroupEnded() { continuation.finish(throwing: RightyoChildError.transportLost) }
        }
    }

    static func coachingWriter(_ descriptor: Int32?, input: RightyoStdinWriter,
                               continuation: AsyncThrowingStream<Data, any Error>.Continuation,
                               revocation: RightyoOutputRevocation? = nil)
        -> RightyoCoachingControlWriter {
        RightyoCoachingControlWriter(descriptor, revocation: revocation) {
            revocation?.revoke()
            input.close(abandon: true)
            continuation.finish(throwing: RightyoChildError.transportLost)
        }
    }
}
extension RightyoStdinWriter {
    /// A private reservation fences even an idle writer. A redundant public off reserves only its control retry.
    func reserve(through sequence: Int?, privacyWanted: Bool = false) -> Int {
        state.withLock { current in
            if current.reserved { release(&current) }
            current.epoch += 1
            current.through = sequence ?? -1
            current.prefixCount = current.queue.count
            current.ordersAudio = privacyWanted || !current.knownPublic
            current.reserved = true
            return current.epoch
        }
    }

    func tighten(starting: Bool, _ write: () -> Bool) -> Bool {
        state.withLock { current in
            if current.reserved && !starting { release(&current) }
            guard write() else { return false }
            current.knownPublic = false
            return true
        }
    }
    func deliver(_ epoch: Int, expired: Bool, write: () -> RightyoDelivery) -> RightyoDelivery {
        state.withLock { current in
            guard current.reserved, current.epoch == epoch else { return .failed }
            guard !current.closing, !current.failed, exit.value == nil else {
                release(&current)
                return .failed
            }
            let busy = (current.inFlight ?? epoch) < epoch || current.prefixCount > 0
                || current.handed < current.through
            if current.ordersAudio && busy && !expired { return .pending }
            let result = exit.whileRunning(write)
            if result == .pending && !expired { return .pending }
            // Still under the stdin lock: seal late private handoffs and retire unwritten PCM at the deadline.
            if current.ordersAudio && (expired || result == .delivered) {
                current.discardedThrough = max(current.discardedThrough, current.through)
                if expired { current.discardBefore = epoch }
            }
            if result == .delivered { current.knownPublic = true }
            release(&current)
            return result == .pending ? .failed : result
        }
    }
}
#endif
