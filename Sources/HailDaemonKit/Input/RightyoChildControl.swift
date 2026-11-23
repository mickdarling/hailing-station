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
    init(_ descriptor: Int32?) { self.descriptor = Mutex(descriptor) }
    /// `asked` (rightyo#199) rides only on an end: a RightyO without it skips the line, as for an unknown key.
    func report(_ phase: RightyoReplyPhase, asked: Bool = false) -> Bool {
        asked && phase == .ended
            ? write("{\"reply\":\"ended\",\"asked\":true}\n")
            : write("{\"reply\":\"\(phase.rawValue)\"}\n")
    }
    /// Media mode (#551, rightyo#195): a RightyO without it skips the line and attends as before.
    func media(_ on: Bool) -> Bool { write("{\"media\":\(on)}\n") }
    /// Duck mode (#735, rightyo R-2). An older RightyO skips the line and keeps deciding turns, so the pipeline writes
    /// it only to a child whose `started` advertised `duck` (`AmbientDuckControl`).
    func duck(_ on: Bool) -> Bool { write("{\"duck\":\(on)}\n") }
    /// Meeting mode (#735 MM-D, rightyo#227): written only to a child whose `started` advertised `meeting` v1
    /// (`AmbientMeetingControl`); exactly that key and a boolean.
    func meeting(_ on: Bool) -> Bool { write("{\"meeting\":\(on)}\n") }
    func outcome(_ outcome: RightyoRequestOutcome) -> Bool {
        guard let line = outcome.line else { return false }
        return write(line)
    }
    private func write(_ text: String) -> Bool {
        let line = Array(text.utf8)
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
    @discardableResult public func reportReply(_ phase: RightyoReplyPhase, asked: Bool = false) -> Bool {
        control.report(phase, asked: asked)
    }
    @discardableResult func reportRequestOutcome(_ value: RightyoRequestOutcome) -> Bool {
        control.outcome(value)
    }
    /// Sets the child's media mode (#551) the same way; false when it could not be written.
    @discardableResult public func reportMedia(_ on: Bool) -> Bool { control.media(on) }
    /// Writes the child's duck mode line (#735) the same way; false when it could not be written. Whether the child
    /// understands it is the caller's to know: `RightyoAmbientPipeline.reportDuck` checks.
    @discardableResult public func reportDuck(_ on: Bool) -> Bool { control.duck(on) }
    /// Writes the child's meeting line (#735 MM-D) the same way; whether it advertised it is the pipeline's to know.
    @discardableResult func reportMeeting(_ on: Bool) -> Bool { control.meeting(on) }

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
#endif
