public import Foundation
import HailProtocol
import Network

public enum LocalReplyEndpointError: Error, Equatable, Sendable {
    case invalidSocketPath
    case socketExists(String)
    case failed(String)
    case stoppedBeforeReady
}

public struct LocalReplyResponse: Codable, Equatable, Sendable {
    public var delivered: Int
    public var error: String?

    public init(delivered: Int, error: String? = nil) {
        self.delivered = delivered
        self.error = error
    }
}

/// Owner-only Unix socket accepting one bounded JSON frame per newline-terminated request.
/// Filesystem ownership and a 0700 parent directory are the local caller authentication boundary.
public actor LocalReplyEndpoint {
    public static let socketName = "replies.sock"
    public static let maxConnections = 16
    public static let maxFramesPerMinute = 120

    public let socketURL: URL
    private let listener: NWListener
    let queue = DispatchQueue(label: "hail.local-reply-endpoint")
    let destination: WebSocketListener
    let audit: AuditLog
    let requestTimeout: Duration
    let clock = ContinuousClock()
    var limiter = RateLimiter()
    var connections: [UUID: NWConnection] = [:]
    private var readyWaiters: [CheckedContinuation<Void, any Error>] = []
    private var readyResult: Result<Void, LocalReplyEndpointError>?
    private var started = false
    private var stopped = false

    public static func standardSocket(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        PolicyFile.standard(environment: environment).directory.appendingPathComponent(socketName)
    }

    public init(
        socketURL: URL, destination: WebSocketListener, audit: AuditLog,
        requestTimeout: Duration = .seconds(5)
    ) throws {
        guard socketURL.isFileURL, !socketURL.path.isEmpty,
              socketURL.path.utf8.count < 104 else { throw LocalReplyEndpointError.invalidSocketPath }
        let directory = socketURL.deletingLastPathComponent()
        let rules = PolicyFile(directory: directory)
        try rules.createDirectoryIfMissing()
        guard let descriptor = try rules.openDirectory() else {
            throw LocalReplyEndpointError.failed("private socket directory unavailable")
        }
        close(descriptor)
        try Self.checkSocketAncestors(directory)
        if try PolicyFile.info(socketURL) != nil {
            throw LocalReplyEndpointError.socketExists(socketURL.path)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketURL.path)
        self.socketURL = socketURL
        self.destination = destination
        self.audit = audit
        self.requestTimeout = requestTimeout
        listener = try NWListener(using: parameters)
    }

    public func start() async throws {
        if let readyResult { return try readyResult.get() }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
            guard !started else { return }
            started = true
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if let info = try? PolicyFile.info(socketURL),
           info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK {
            unlink(socketURL.path)
        }
        if readyResult == nil { finishReady(.failure(.stoppedBeforeReady)) }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            do {
                try secureSocket()
                finishReady(.success(()))
            } catch {
                finishReady(.failure(.failed("could not secure local reply socket")))
                stop()
            }
        case .failed(let error):
            finishReady(.failure(.failed("\(error)")))
            stop()
        case .cancelled:
            if !stopped { stop() }
        case .setup, .waiting:
            break
        @unknown default:
            finishReady(.failure(.failed("unknown listener state")))
            stop()
        }
    }

    private func secureSocket() throws {
        guard chmod(socketURL.path, 0o600) == 0,
              let info = try PolicyFile.info(socketURL) else {
            throw LocalReplyEndpointError.failed("socket mode unavailable")
        }
        try PolicyFile.check(info, at: socketURL, type: S_IFSOCK)
    }

    private func finishReady(_ result: Result<Void, LocalReplyEndpointError>) {
        guard readyResult == nil else { return }
        readyResult = result
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            switch result {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, readyResult != nil, connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.retire(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(LocalReplyConnection(id: id, connection: connection), buffer: Data())
        let timeout = requestTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.retire(id)
        }
    }
}

extension LocalReplyEndpoint {
    var activeConnectionCount: Int { connections.count }

    /// Network.framework binds Unix sockets by path, not relative to an open directory descriptor.
    /// Refuse an ancestry another local user can rename while the listener starts, so the directory
    /// checked above remains the directory in which the socket is created and later removed.
    private static func checkSocketAncestors(_ directory: URL) throws {
        var candidate = directory
        while true {
            var info = stat()
            guard stat(candidate.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == getuid(),
                  info.st_mode & 0o022 == 0 else {
                throw LocalReplyEndpointError.failed(
                    "socket path has an unsafe ancestor: \(candidate.path)"
                )
            }
            guard candidate.path != "/" else { return }
            candidate = candidate.deletingLastPathComponent()
        }
    }
}
