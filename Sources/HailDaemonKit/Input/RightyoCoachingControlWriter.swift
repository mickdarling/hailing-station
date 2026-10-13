#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// Explicit foreground capability, absent from ordinary ambient/reply child startup.
public struct RightyoCoachingLaunch: Sendable {
    public let mockSuggestions: URL?
    public init(mockSuggestions: URL? = nil) { self.mockSuggestions = mockSuggestions }
    func arguments(session: String, provenance: RightyoAudioProvenance) throws -> [String] {
        guard let id = UUID(uuidString: session), id.uuidString.lowercased() == session,
              session != "00000000-0000-0000-0000-000000000000" else { throw RightyoChildError.unsafeConfig }
        guard let mockSuggestions else { return ["--coaching"] }
        var info = stat()
        guard provenance == .synthetic, mockSuggestions.isFileURL, mockSuggestions.path.hasPrefix("/"),
              stat(mockSuggestions.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 65_536, access(mockSuggestions.path, R_OK) == 0 else {
            throw RightyoChildError.unsafeConfig
        }
        return ["--coaching", "--coaching-mock-suggestions", mockSuggestions.path]
    }
}

/// Serialized nonblocking partial writes: profiles can exceed PIPE_BUF. Failure closes the channel
/// and revokes the child stream, never dropping/splicing partial JSON. Original deadline and 250ms
/// queue/pipe budget are checked before every write. No other writer shares this owned fd.
final class RightyoCoachingControlWriter: Sendable {
    private struct Line: Sendable { let data: Data, deadline: ContinuousClock.Instant; var offset = 0 }
    private struct State {
        var descriptor: Int32?
        var lines: [Line] = []
        var bytes = 0, records = 0
        var draining = false, failed = false
    }
    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "hailing.rightyo.coaching-control")
    private let failed: @Sendable () -> Void
    init(_ descriptor: Int32?, failed: @escaping @Sendable () -> Void) {
        state = Mutex(State(descriptor: descriptor)); self.failed = failed
    }
    deinit { close() }

    func send(_ data: Data, validUntil deadline: ContinuousClock.Instant) -> Bool {
        let now = ContinuousClock.now
        guard !data.isEmpty, data.count <= 8_192, !data.contains(10), !data.contains(13),
              data.allSatisfy({ $0 < 128 }), now < deadline else { fail(); return false }
        let accepted = state.withLock { current -> Bool in
            guard current.descriptor != nil, !current.failed, current.records < 4_096,
                  current.lines.count < 128, current.bytes + data.count + 1 <= 32_768 else { return false }
            current.lines.append(Line(data: data + Data([10]),
                                      deadline: min(deadline, now.advanced(by: .milliseconds(250)))))
            current.bytes += data.count + 1; current.records += 1
            if !current.draining { current.draining = true; queue.async { self.drain() } }
            return true
        }
        if !accepted { fail() }
        return accepted
    }

    func close() {
        state.withLock { current in
            if let fd = current.descriptor { Darwin.close(fd) }
            current.descriptor = nil; current.lines.removeAll(); current.bytes = 0
        }
    }

    private func fail() {
        let notify = state.withLock { current in
            let first = !current.failed && current.descriptor != nil
            current.failed = true
            if let fd = current.descriptor { Darwin.close(fd) }
            current.descriptor = nil; current.lines.removeAll(); current.bytes = 0
            return first
        }
        if notify { failed() }
    }

    private enum Progress { case more, waiting, done, failure }
    private func step() -> Progress {
        state.withLock { current in
            guard let fd = current.descriptor, !current.lines.isEmpty else {
                current.draining = false; return .done
            }
            var line = current.lines[0]
            guard ContinuousClock.now < line.deadline else { return .failure }
            let count = line.data.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress?.advanced(by: line.offset), line.data.count - line.offset)
            }
            if count > 0 {
                line.offset += count
                if line.offset == line.data.count {
                    current.bytes -= line.data.count; current.lines.removeFirst()
                } else { current.lines[0] = line }
                return .more
            }
            if count < 0, errno == EINTR { return .more }
            return count < 0 && errno == EAGAIN ? .waiting : .failure
        }
    }

    private func drain() {
        while true {
            switch step() {
            case .more: continue
            case .done: return
            case .failure: fail(); return
            case .waiting: queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.drain() }; return
            }
        }
    }
}
#endif
