#if os(macOS)
import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// A device whose WebSocket stack never answers a ping (`autoReplyPing` off, and nothing read once it is set up), as
/// a dropped phone's socket haild still holds open. The app's own transport, `URLSessionWebSocketTask`, answers pings
/// itself, as the rig's other devices do. Synthetic only; every wait bounded.
final class SilentPeer: @unchecked Sendable {
    let connection: NWConnection

    private init(_ connection: NWConnection) { self.connection = connection }

    /// A peer connected to the loopback listener on `port`, ready to send (#963). A busy parallel run churns loopback
    /// listeners and connections, and the system's port choice can repeat a local and remote port pair still in
    /// TIME_WAIT from an earlier connection: the connection then waits (`EADDRINUSE`), never retries on its own, and
    /// a send on it hung until the 15 s bound cancelled it. A fresh connection is given the same local port again, so
    /// a connection that cannot take its address, which never reached the listener, is cancelled and the next attempt
    /// binds a random local port instead, at most `attempts` times. Any other failure, or no answer in 15 s, is thrown.
    static func connect(port: UInt16, attempts: Int = 8) async throws -> SilentPeer {
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
        var refused: NWError?
        for attempt in 0..<attempts {
            let options = NWProtocolWebSocket.Options(.version13)
            options.autoReplyPing = false
            options.setSubprotocols([WebSocketListener.subprotocolName])
            let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            if attempt > 0, let local = NWEndpoint.Port(rawValue: UInt16.random(in: 49_152...65_535)) {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: local)
            }
            let connection = NWConnection(to: .url(url), using: parameters)
            refused = try await ready(connection)
            guard refused != nil else { return SilentPeer(connection) }
            connection.cancel()
        }
        Issue.record("silent peer took no local address in \(attempts) connects: \(String(describing: refused))")
        throw SilentPeerNotReady()
    }

    /// Starts `connection` and returns nil once it is ready, or the error if it waits, or fails, because it could not
    /// take its local address (it never reached the listener then). Throws on any other failure, or if it is neither
    /// within 15 s (it is cancelled then).
    private static func ready(_ connection: NWConnection) async throws -> NWError? {
        let readiness = SilentPeerReadiness()
        let timer = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            readiness.set(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: readiness.resume(.success(nil))
                case .waiting(let error): readiness.resume(.success(error))
                case .failed(.posix(.EADDRINUSE)): readiness.resume(.success(.posix(.EADDRINUSE)))
                case .failed(let error): readiness.resume(.failure(error))
                case .cancelled: readiness.resume(.failure(SilentPeerNotReady()))
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }

    func send(_ frame: Frame) async throws {
        let context = NWConnection.ContentContext(identifier: "silent", metadata: [
            NWProtocolWebSocket.Metadata(opcode: .binary)
        ])
        let data = try FrameCoding.encode(frame)
        try await bounded { done in
            self.connection.send(content: data, contentContext: context, isComplete: true,
                                 completion: .contentProcessed { done($0.map { $0 as any Error }) })
        }
    }

    /// The next frame, skipping control messages (it never answers a ping).
    func receive() async throws -> Frame {
        while true {
            let message = Mutex<(Data, Bool)?>(nil)
            try await bounded { done in
                self.connection.receiveMessage { data, context, _, error in
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata
                    let control = metadata.map { $0.opcode != .binary && $0.opcode != .text } ?? true
                    message.withLock { $0 = (data ?? Data(), control) }
                    done(error)
                }
            }
            if let received = message.withLock({ $0 }), !received.1 { return try FrameCoding.decode(received.0) }
        }
    }

    func cancel() { connection.cancel() }

    /// From now on reads every message, and answers each ping `delay` late, as a slow peer would (#941); other frames
    /// are dropped. Ends with the connection.
    func answerPingsLate(after delay: Duration) {
        let connection = connection
        Task {
            while true {
                let ping = Mutex<Data?>(nil)
                let failed = Mutex(false)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    connection.receiveMessage { data, context, _, error in
                        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                            as? NWProtocolWebSocket.Metadata
                        if metadata?.opcode == .ping { ping.withLock { $0 = data ?? Data() } }
                        failed.withLock { $0 = error != nil || context == nil }
                        continuation.resume()
                    }
                }
                if failed.withLock({ $0 }) { return }
                guard let payload = ping.withLock({ $0 }) else { continue }
                try? await Task.sleep(for: delay)
                let pong = NWConnection.ContentContext(identifier: "late-pong", metadata: [
                    NWProtocolWebSocket.Metadata(opcode: .pong)
                ])
                connection.send(content: payload, contentContext: pong, isComplete: true, completion: .idempotent)
            }
        }
    }

    /// Runs `operation` until it calls back, or cancels the connection after 15 s, so no wait outlives the suite.
    private func bounded(_ operation: (@escaping @Sendable ((any Error)?) -> Void) -> Void) async throws {
        let connection = connection
        let timer = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            operation { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// A silent peer's connection was not ready in time, or never stopped waiting (#963).
struct SilentPeerNotReady: Error {}

/// The one answer of a silent peer's connect attempt: its first ready, waiting, failed or cancelled state.
private final class SilentPeerReadiness: Sendable {
    private let waiter = Mutex<CheckedContinuation<NWError?, any Error>?>(nil)
    func set(_ continuation: CheckedContinuation<NWError?, any Error>) { waiter.withLock { $0 = continuation } }
    func resume(_ result: Result<NWError?, any Error>) { waiter.withLock { $0.take() }?.resume(with: result) }
}
#endif
