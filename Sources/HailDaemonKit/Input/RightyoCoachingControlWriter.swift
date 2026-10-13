#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// Coaching-only delivery fence. Ordinary child EOF continues to deliver its buffered terminal lines.
final class RightyoOutputRevocation: Sendable {
    private let state = Mutex(false)
    func revoke() { state.withLock { $0 = true } }
    func check() throws {
        if state.withLock({ $0 }) { throw RightyoChildError.transportLost }
    }
}

/// The existing byte-bounded stdout reader with a coaching-only fence before and after suspension.
public struct RightyoChildOutput: AsyncSequence, Sendable {
    let base: RightyoChildLines
    let revocation: RightyoOutputRevocation?
    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: RightyoChildLines.AsyncIterator
        let revocation: RightyoOutputRevocation?
        public mutating func next() async throws -> Data? {
            try revocation?.check()
            let line = try await base.next()
            try revocation?.check()
            return line
        }
    }
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), revocation: revocation)
    }
    func revokeCoaching() { revocation?.revoke() }
}

/// Explicit foreground capability, absent from ordinary ambient/reply child startup.
public enum RightyoCoachingProvider: Sendable {
    case mock
    case jev(hostedTextConsent: Bool, maxRequests: Int, adviceCatalog: URL)
}

public struct RightyoCoachingLaunch: Sendable {
    public let mockSuggestions: URL?
    public let provider: RightyoCoachingProvider
    public init(mockSuggestions: URL? = nil, provider: RightyoCoachingProvider = .mock) {
        self.mockSuggestions = mockSuggestions; self.provider = provider
    }
    func arguments(session: String, provenance: RightyoAudioProvenance) throws -> [String] {
        guard let id = UUID(uuidString: session), id.uuidString.lowercased() == session,
              session != "00000000-0000-0000-0000-000000000000" else { throw RightyoChildError.unsafeConfig }
        if case let .jev(consent, budget, catalog) = provider {
            var info = stat()
            guard consent, (1...100).contains(budget), mockSuggestions == nil,
                  catalog.isFileURL, catalog.path.hasPrefix("/"), !catalog.path.contains("\0"),
                  stat(catalog.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  (1...8_192).contains(info.st_size), access(catalog.path, R_OK) == 0 else {
                throw RightyoChildError.unsafeConfig
            }
            return ["--coaching", "--coaching-provider", "jev", "--coaching-allow-hosted-text",
                    "--coaching-max-requests", String(budget), "--coaching-advice-catalog", catalog.path]
        }
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
