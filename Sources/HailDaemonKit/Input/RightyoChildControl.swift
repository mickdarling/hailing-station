#if os(macOS)
import Darwin
public import Foundation
import Synchronization

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
    /// When `enabled`, a close-on-exec pipe whose write end never blocks or raises SIGPIPE; true when not enabled.
    static func controlPipe(_ ends: inout [Int32], _ enabled: Bool) -> Bool {
        guard enabled else { return true }
        return pipe(&ends) == 0 && ends.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 })
            && fcntl(ends[1], F_SETNOSIGPIPE, 1) == 0 && fcntl(ends[1], F_SETFL, O_NONBLOCK) == 0
    }
    /// Reports the assistant's spoken reply to the child (rightyo#124) without blocking; false when the child was
    /// started without `replyControl`, its control input is closed, or the pipe is full (the report is dropped).
    @discardableResult public func reportReply(_ phase: RightyoReplyPhase) -> Bool { control.report(phase) }
}
#endif
