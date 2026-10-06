import CryptoKit
public import Foundation
import Synchronization

/// What the running daemon reports about itself for `haild status --json` and `haild doctor` (#247). It is
/// written beside the policy file and holds no transcript, peer address or device identifier, so it is
/// safe to paste.
public struct DaemonStatus: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public struct Listener: Codable, Sendable, Equatable {
        /// `starting`, `ready`, `waiting`, `failed` or `stopped`.
        public var state: String
        /// The daemon's own bind address and port, once ready.
        public var endpoint: String?
        /// The listener's error for `waiting` and `failed`, or the stop reason.
        public var detail: String?
    }

    public var schema: Int
    public var version: String
    public var build: String?
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date
    public var hostID: String
    public var listener: Listener
    public var connectedSessions: Int

    /// `status.json` beside the standard policy file, including `HAIL_CONFIG_DIR` overrides.
    public static func standardFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        PolicyFile.standard(environment: environment).directory.appendingPathComponent("status.json")
    }

    /// `nil` when there is no snapshot or it cannot be decoded, for example one from a newer schema.
    public static func read(from file: URL) -> DaemonStatus? {
        guard let data = try? Data(contentsOf: file),
              let status = try? JSONDecoder.hailStatus.decode(DaemonStatus.self, from: data),
              status.schema == currentSchema else { return nil }
        return status
    }
}

/// The running executable's identity: the first 16 hex characters of its SHA-256, the same prefix
/// `scripts/host.sh` names each installed release after (#246). The daemon and the CLI each hash their own
/// binary, so a mismatch is build skew (#115, #247) without any build-time stamping.
public enum BuildIdentity {
    /// `nil` when the file cannot be read in full.
    public static func digest(of executable: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return nil
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// This process's executable, through any link (the `haild` on PATH links into a release).
    public static func current() -> String? {
        Bundle.main.executableURL.flatMap { digest(of: $0.resolvingSymlinksInPath()) }
    }
}

/// Keeps `DaemonStatus` current from the daemon's own events and rewrites the file on every change, under the
/// lock so concurrent events never leave an older snapshot behind. A write failure never reaches the caller:
/// the daemon keeps serving, and `doctor` reports a stale snapshot. A snapshot that belongs to another live
/// daemon is left alone, so a second `haild run` (a duplicate launch, a crash-looping job) that fails to bind
/// cannot make `doctor` report the serving daemon as dead.
public final class DaemonStatusRecorder: Sendable {
    private struct State {
        var status: DaemonStatus
        var sessions: Set<UUID> = []
    }

    private let file: URL
    private let now: @Sendable () -> Date
    private let isRunning: @Sendable (Int32) -> Bool
    private let state: Mutex<State>

    public init(
        file: URL, hostID: String, build: String?,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: @escaping @Sendable () -> Date = Date.init,
        isRunning: @escaping @Sendable (Int32) -> Bool = HealthReport.processIsRunning
    ) {
        self.file = file
        self.now = now
        self.isRunning = isRunning
        let started = now()
        state = Mutex(State(status: DaemonStatus(
            schema: DaemonStatus.currentSchema, version: DaemonInfo.version, build: build, pid: pid,
            startedAt: started, updatedAt: started, hostID: hostID,
            listener: .init(state: "starting"), connectedSessions: 0
        )))
        state.withLock { write($0.status) }
    }

    public func observe(_ event: WebSocketListenerEvent) {
        state.withLock { state in
            switch event.event {
            case "listener_ready": state.status.listener = .init(state: "ready", endpoint: event.endpoint)
            case "listener_waiting": state.status.listener = .init(state: "waiting", detail: event.detail)
            case "listener_failed": state.status.listener = .init(state: "failed", detail: event.detail)
            case "listener_stopped":
                state.status.listener = .init(state: "stopped", detail: event.detail)
                state.sessions.removeAll()
            case "session_connected":
                guard let id = event.sessionID else { return }
                state.sessions.insert(id)
            case "session_disconnected":
                guard let id = event.sessionID else { return }
                state.sessions.remove(id)
            default: return
            }
            state.status.connectedSessions = state.sessions.count
            state.status.updatedAt = now()
            write(state.status)
        }
    }

    /// Owner-only, and atomic: a reader sees the old snapshot or the new one, never a partial file.
    private func write(_ status: DaemonStatus) {
        if let current = DaemonStatus.read(from: file), current.pid != status.pid,
           current.listener.state != "stopped", isRunning(current.pid) { return }
        guard let data = try? JSONEncoder.hailStatus.encode(status) else { return }
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]
        ) else { return }
        if rename(temporary.path, file.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }
}

extension JSONEncoder {
    /// Sorted, readable JSON with ISO-8601 dates, for the status file and `haild status --json`.
    public static var hailStatus: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var hailStatus: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
