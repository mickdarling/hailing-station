#if os(macOS)
import Foundation
import Network
import Synchronization
@testable import HailDaemonKit

/// TEMPORARY #971 diagnostics (diag branch only, never merged). Token-only: loopback ports, counts, connection id
/// prefixes, state names and event names. No frame content, no file paths.
enum Diag971 {
    static let start = ContinuousClock.now
    private static let lines = Mutex<[String: [String]]>([:])
    private static let ports = Mutex<[UInt16: String]>([:])
    static func ms() -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
    static func register(port: UInt16, tag: String) { ports.withLock { $0[port] = tag } }
    /// The rig's listener started, its port tagged.
    static func started(_ listener: WebSocketListener, tag: String) async throws -> UInt16 {
        let port = try await boundedAmbientListenerStart(listener)
        register(port: port, tag: tag)
        note(tag, "rig port=\(port)")
        return port
    }
    /// The router's log, also noting each event's name under `tag`.
    static func wrap(_ tag: String, _ base: @escaping @Sendable (WebSocketListenerEvent) -> Void)
        -> @Sendable (WebSocketListenerEvent) -> Void {
        { event in
            base(event)
            router(tag, event)
        }
    }
    static func tag(port: UInt16) -> String? { ports.withLock { $0[port] } }
    static func note(_ tag: String, _ what: String) {
        lines.withLock { $0[tag, default: []].append("t=\(ms()) \(what)") }
    }
    /// A note keyed by a client connection's remote (listener) port.
    static func client(_ connection: NWConnection, _ what: String) {
        guard case .url(let url) = connection.endpoint, let port = url.port, let remote = UInt16(exactly: port) else {
            return
        }
        note(port: remote, what)
    }
    static func note(port: UInt16, _ what: String) { if let tag = tag(port: port) { note(tag, what) } }
    /// Listener events: names, session id prefixes, loopback endpoints; details only for the session/diag/listener
    /// vocabulary (reasons and NW states).
    static func listener(_ tag: String, _ event: WebSocketListenerEvent) {
        let keepDetail = ["session_", "diag_", "listener_"].contains { event.event.hasPrefix($0) }
        note(tag, "L \(event.event) sid=\(event.sessionID.map { String($0.uuidString.prefix(8)) } ?? "-") "
            + "ep=\(event.endpoint ?? "-")" + (keepDetail ? " d=\(event.detail ?? "-")" : ""))
    }
    /// Router events: names only.
    static func router(_ tag: String, _ event: WebSocketListenerEvent) { note(tag, "R \(event.event)") }
    static func ids(_ set: Set<UUID>) -> String {
        set.map { String($0.uuidString.prefix(8)) }.sorted().joined(separator: ",")
    }
    static func dump(tag: String, _ header: String) {
        let body = lines.withLock { $0[tag] ?? [] }.joined(separator: "\n  ")
        FileHandle.standardError.write(Data("#971DIAG t=\(ms()) \(header) tag=\(tag)\n  \(body)\n#971DIAG end\n".utf8))
    }
    static func dump(port: UInt16, _ header: String) { dump(tag: tag(port: port) ?? "?", header + " port=\(port)") }
    static func state(_ state: NWConnection.State) -> String {
        switch state {
        case .setup: "setup"
        case .preparing: "preparing"
        case .ready: "ready"
        case .waiting(let error): "waiting(\(code(error)))"
        case .failed(let error): "failed(\(code(error)))"
        case .cancelled: "cancelled"
        @unknown default: "unknown"
        }
    }
    static func code(_ error: (any Error)?) -> String {
        guard let error else { return "nil" }
        if let nw = error as? NWError, case .posix(let posix) = nw { return "posix\(posix.rawValue)" }
        if let nw = error as? NWError { return "nw:\(nw.errorCode)" }
        return String(describing: type(of: error))
    }
    static func local(_ connection: NWConnection) -> String {
        guard case .hostPort(_, let port)? = connection.currentPath?.localEndpoint else { return "-" }
        return "\(port.rawValue)"
    }
}
#endif
