import Darwin
import Foundation
import HailDaemonKit
import Network

/// Test-only owner-local responder for transport and CLI compatibility failures.
actor VoiceGuardsReplyStub {
    private let socket: URL
    private let listener: NWListener
    private let reply: String?
    private let queue = DispatchQueue(label: "hail.voice-status-test")
    private var clients: [NWConnection] = []
    private(set) var requestsAreStatusOnly = true
    private(set) var requestCount = 0

    init(socket: URL, reply: String?) throws {
        self.socket = socket
        self.reply = reply
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socket.path)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [listener, socket] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if chmod(socket.path, 0o600) == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: CocoaError(.fileWriteNoPermission))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        clients.append(connection)
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, done, error in
            Task { await self?.received(connection, data: data, buffer: buffer, ended: done || error != nil) }
        }
    }

    private func received(_ connection: NWConnection, data: Data?, buffer: Data, ended: Bool) {
        var frame = buffer
        if let data { frame.append(data) }
        if let newline = frame.firstIndex(of: 10) {
            requestCount += 1
            let request = try? JSONSerialization.jsonObject(with: frame[..<newline]) as? [String: String]
            requestsAreStatusOnly = requestsAreStatusOnly && request == ["kind": "voice-guards", "action": "status"]
            guard let reply else { return } // Hold the connection to exercise the real client deadline.
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
        } else if !ended && frame.count < 4_096 {
            receive(connection, buffer: frame)
        } else {
            connection.cancel()
        }
    }

    func stop() {
        listener.cancel()
        for client in clients { client.cancel() }
        clients.removeAll()
    }
}
