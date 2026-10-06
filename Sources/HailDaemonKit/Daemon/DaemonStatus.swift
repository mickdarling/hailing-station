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

/// Keeps `DaemonStatus` current from the daemon's own events and rewrites the file on every change. A write
/// failure never reaches the caller: the daemon keeps serving, and `doctor` reports a stale snapshot.
public final class DaemonStatusRecorder: Sendable {
    private struct State {
        var status: DaemonStatus
        var sessions: Set<UUID> = []
    }

    private let file: URL
    private let now: @Sendable () -> Date
    private let state: Mutex<State>

    public init(
        file: URL, hostID: String, build: String?,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.file = file
        self.now = now
        let started = now()
        state = Mutex(State(status: DaemonStatus(
            schema: DaemonStatus.currentSchema, version: DaemonInfo.version, build: build, pid: pid,
            startedAt: started, updatedAt: started, hostID: hostID,
            listener: .init(state: "starting"), connectedSessions: 0
        )))
        write(state.withLock { $0.status })
    }

    public func observe(_ event: WebSocketListenerEvent) {
        let changed: DaemonStatus? = state.withLock { state in
            switch event.event {
            case "listener_ready": state.status.listener = .init(state: "ready", endpoint: event.endpoint)
            case "listener_waiting": state.status.listener = .init(state: "waiting", detail: event.detail)
            case "listener_failed": state.status.listener = .init(state: "failed", detail: event.detail)
            case "listener_stopped":
                state.status.listener = .init(state: "stopped", detail: event.detail)
                state.sessions.removeAll()
            case "session_connected":
                guard let id = event.sessionID else { return nil }
                state.sessions.insert(id)
            case "session_disconnected":
                guard let id = event.sessionID else { return nil }
                state.sessions.remove(id)
            default: return nil
            }
            state.status.connectedSessions = state.sessions.count
            state.status.updatedAt = now()
            return state.status
        }
        if let changed { write(changed) }
    }

    /// Owner-only, and atomic: a reader sees the old snapshot or the new one, never a partial file.
    private func write(_ status: DaemonStatus) {
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
