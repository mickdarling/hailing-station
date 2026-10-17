#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// Coaching failure/abandonment revokes output; explicit graceful EOF preserves buffered terminal lines.
final class RightyoOutputRevocation: Sendable {
    private struct State { var revoked = false, graceful = false }
    private let state = Mutex(State())
    func revoke() { state.withLock { $0.revoked = true } }
    func noteGracefulInputClosure() { state.withLock { $0.graceful = true } }
    func ownedGroupEnded() { state.withLock { if !$0.graceful { $0.revoked = true } } }
    func check() throws {
        if state.withLock({ $0.revoked }) { throw RightyoChildError.transportLost }
    }
}

/// The existing byte-bounded stdout reader with a coaching-only fence before and after suspension.
public struct RightyoChildOutput: AsyncSequence, Sendable {
    let base: RightyoChildLines
    let revocation: RightyoOutputRevocation?
    let control: RightyoCoachingControlWriter?
    init(base: RightyoChildLines, revocation: RightyoOutputRevocation?,
         control: RightyoCoachingControlWriter? = nil) {
        self.base = base; self.revocation = revocation; self.control = control
    }
    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: RightyoChildLines.AsyncIterator
        let revocation: RightyoOutputRevocation?
        let control: RightyoCoachingControlWriter?
        public mutating func next() async throws -> Data? {
            try revocation?.check()
            guard control?.peerAvailable() != false else { throw RightyoChildError.transportLost }
            let line = try await base.next()
            try revocation?.check()
            guard control?.peerAvailable() != false else { throw RightyoChildError.transportLost }
            return line
        }
    }
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), revocation: revocation, control: control)
    }
    func revokeCoaching() { revocation?.revoke() }
}

/// What the host reports about the assistant's spoken reply (rightyo#124).
public enum RightyoReplyPhase: String, Sendable { case started, ended }

/// The child's control descriptor (rightyo#124): one short JSON line per report, written without blocking. A line
/// is under `PIPE_BUF`, so each write is atomic: whole, or refused (a full pipe or a gone child) and dropped.
final class RightyoControlWriter: Sendable {
    private let descriptor: Mutex<Int32?>
    init(_ descriptor: Int32?) { self.descriptor = Mutex(descriptor) }
    func report(_ phase: RightyoReplyPhase) -> Bool {
        let line = Array("{\"reply\":\"\(phase.rawValue)\"}\n".utf8)
        return descriptor.withLock { fd in
            guard let fd else { return false }
            return line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == line.count
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
    /// Reports the assistant's spoken reply to the child (rightyo#124) without blocking; false when the child was
    /// started without `replyControl`, its control input is closed, or the pipe is full (the report is dropped).
    @discardableResult public func reportReply(_ phase: RightyoReplyPhase) -> Bool { control.report(phase) }

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
#endif
