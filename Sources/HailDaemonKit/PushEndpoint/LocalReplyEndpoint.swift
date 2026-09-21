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
    let destination: any HostReplyPublishing
    let audit: AuditLog
    let requestTimeout: Duration
    let submissionTimeout: Duration
    let clock = ContinuousClock()
    var limiter = RateLimiter()
    var connections: [UUID: NWConnection] = [:]
    var awaitingFrames: Set<UUID> = []
    var submissionTasks: [UUID: Task<Void, Never>] = [:]
    private var readyWaiters: [CheckedContinuation<Void, any Error>] = []
    var readyResult: Result<Void, LocalReplyEndpointError>?
    private var started = false
    var stopped = false

    public static func standardSocket(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        PolicyFile.standard(environment: environment).directory.appendingPathComponent(socketName)
    }

    public init(
        socketURL: URL, destination: any HostReplyPublishing, audit: AuditLog,
        requestTimeout: Duration = .seconds(5), submissionTimeout: Duration = .seconds(10)
    ) throws {
        guard socketURL.isFileURL, !socketURL.path.isEmpty else {
            throw LocalReplyEndpointError.invalidSocketPath
        }
        let requestedDirectory = socketURL.deletingLastPathComponent()
        let rules = PolicyFile(directory: requestedDirectory)
        try rules.createDirectoryIfMissing()
        guard let descriptor = try rules.openDirectory() else {
            throw LocalReplyEndpointError.failed("private socket directory unavailable")
        }
        close(descriptor)
        let directory = try Self.resolvedDirectory(requestedDirectory)
        let resolvedSocketURL = directory.appendingPathComponent(socketURL.lastPathComponent)
        guard resolvedSocketURL.path.utf8.count < 104 else {
            throw LocalReplyEndpointError.invalidSocketPath
        }
        try Self.checkSocketAncestors(directory)
        if try PolicyFile.info(resolvedSocketURL) != nil {
            throw LocalReplyEndpointError.socketExists(resolvedSocketURL.path)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: resolvedSocketURL.path)
        self.socketURL = resolvedSocketURL
        self.destination = destination
        self.audit = audit
        self.requestTimeout = requestTimeout
        self.submissionTimeout = submissionTimeout
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
        for task in submissionTasks.values { task.cancel() }
        submissionTasks.removeAll()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        awaitingFrames.removeAll()
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
}
