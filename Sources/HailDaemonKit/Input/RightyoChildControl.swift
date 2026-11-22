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

/// What the host reports about the assistant's spoken reply (rightyo#124).
public enum RightyoReplyPhase: String, Sendable { case started, ended }

/// The child's control descriptor (rightyo#124): one short JSON line per report, written without blocking. A line
/// is under `PIPE_BUF`, so each write is atomic: whole, or refused (a full pipe or a gone child) and dropped.
final class RightyoControlWriter: Sendable {
    typealias Schedule = @Sendable (@escaping @Sendable () -> Void) -> Void
    private static let deadlines = DispatchQueue(label: "hailing.rightyo-child.duck-deadline")
    private struct State {
        var descriptor: Int32?, pending: UUID?
        var duckOn: Bool

        mutating func writeDuck(_ on: Bool, to descriptor: Int32) -> Bool {
            guard RightyoControlWriter.write("{\"duck\":\(on)}\n", to: descriptor) else { return false }
            duckOn = on
            return true
        }
    }
    private let state: Mutex<State>
    private let schedule: Schedule

    init(_ descriptor: Int32?, startPrivate: Bool = false, schedule: @escaping Schedule = { action in
        RightyoControlWriter.deadlines.asyncAfter(deadline: .now() + .milliseconds(500), execute: action)
    }) {
        state = Mutex(State(descriptor: descriptor, duckOn: startPrivate))
        self.schedule = schedule
    }
    /// `asked` (rightyo#199) rides only on an end: a RightyO without it skips the line, as for an unknown key.
    func report(_ phase: RightyoReplyPhase, asked: Bool = false) -> Bool {
        asked && phase == .ended
            ? write("{\"reply\":\"ended\",\"asked\":true}\n")
            : write("{\"reply\":\"\(phase.rawValue)\"}\n")
    }
    /// Media mode (#551, rightyo#195): a RightyO without it skips the line and attends as before.
    func media(_ on: Bool) -> Bool { write("{\"media\":\(on)}\n") }
    func duck(_ on: Bool, after input: RightyoStdinWriter) -> Bool {
        state.withLock { current in
            guard let descriptor = current.descriptor else { return false }
            if on || !current.duckOn {
                current.pending = nil
                return current.writeDuck(on, to: descriptor)
            }
            if current.pending != nil { return true }
            let token = UUID()
            let boundary = input.afterQueued { [weak self, weak input] in
                self?.finish(token, input: input, discardBefore: nil)
            }
            switch boundary {
            case .closed: return false
            case .ready: return current.writeDuck(false, to: descriptor)
            case .pending(let epoch):
                current.pending = token
                schedule { [weak self, weak input] in self?.finish(token, input: input, discardBefore: epoch) }
                return true
            }
        }
    }

    private func finish(_ token: UUID, input: RightyoStdinWriter?, discardBefore epoch: Int?) {
        state.withLock { current in
            guard current.pending == token else { return }
            current.pending = nil
            guard let descriptor = current.descriptor, let input,
                  input.finishBoundary(discardBefore: epoch) else { return }
            _ = current.writeDuck(false, to: descriptor)
        }
    }

    /// Meeting mode (#735 MM-D, rightyo#227): written only to a child whose `started` advertised `meeting` v1
    /// (`AmbientMeetingControl`); exactly that key and a boolean.
    func meeting(_ on: Bool) -> Bool { write("{\"meeting\":\(on)}\n") }
    func outcome(_ outcome: RightyoRequestOutcome) -> Bool {
        guard let line = outcome.line else { return false }
        return write(line)
    }
    private func write(_ text: String) -> Bool {
        state.withLock { current in
            guard let descriptor = current.descriptor else { return false }
            return Self.write(text, to: descriptor)
        }
    }

    private static func write(_ text: String, to descriptor: Int32) -> Bool {
        let line = Array(text.utf8)
        return line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } == line.count
    }

    func close() {
        state.withLock { current in
            if let descriptor = current.descriptor { Darwin.close(descriptor) }
            current.descriptor = nil
            current.pending = nil
        }
    }

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
    /// An on is written immediately. An off can be admitted for delivery after queued stdin.
    @discardableResult public func reportDuck(_ on: Bool) -> Bool { control.duck(on, after: input) }
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
